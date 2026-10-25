package app.airwave.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// The private catalog (JSON version 2). Provider URLs and artwork sources stay here; the web view gets
// airwave-native:// media IDs and same-origin artwork addresses.
class Catalog(private val store: CatalogStore) {
    private var name = "My library"
    private var order: JSONArray? = null
    private val media = HashMap<String, JSONObject>()

    @Synchronized fun open(): JSONObject? {
        if (order == null) store.read()?.let { load(it) }
        return if (order == null) null else snapshot()
    }

    @Synchronized fun import(data: ByteArray): JSONObject {
        val previous = Triple(name, order, HashMap(media))
        try {
            load(data); store.write(data)
            return snapshot()
        } catch (error: Exception) {
            name = previous.first; order = previous.second; media.clear(); media.putAll(previous.third)
            throw error
        }
    }

    @Synchronized fun url(id: String): String? = media[id]?.optString("url")
    @Synchronized fun kind(id: String): String? = media[id]?.optString("kind")
    @Synchronized fun logo(id: String): String? = media[id]?.optString("logo")?.takeIf { Net.isHttp(it) }

    private fun load(data: ByteArray) {
        if (data.size > 100_000_000) throw IOException("Library too large")
        val json = JSONObject(String(data, Charsets.UTF_8))
        val items = json.optJSONArray("items") ?: throw IOException("No items")
        if (items.length() == 0 || items.length() > 200_000) throw IOException("Item count out of range")
        val accepted = HashMap<String, JSONObject>()
        for (index in 0 until items.length()) {
            val item = items.optJSONObject(index) ?: continue
            val id = item.opt("id") as? String ?: continue
            if (!Net.isHttp(item.opt("url") as? String) || item.opt("name") !is String) continue
            if (item.optString("kind") != "live" && item.optString("kind") != "movie") continue
            accepted[id] = item
        }
        if (accepted.isEmpty()) throw IOException("No playable items")
        name = json.optString("name").ifEmpty { "My library" }
        order = items; media.clear(); media.putAll(accepted)
    }

    private fun snapshot(): JSONObject {
        val items = JSONArray()
        val all = order ?: JSONArray()
        for (index in 0 until all.length()) {
            val item = all.optJSONObject(index) ?: continue
            val id = item.opt("id") as? String ?: continue
            if (!media.containsKey(id)) continue
            val safe = JSONObject(item.toString())
            safe.remove("source")
            safe.put("url", "airwave-native://$id")
            safe.put("logo", if (logo(id) != null) Artwork.address(id) else "")
            items.put(safe)
        }
        return JSONObject().put("version", 2).put("private", true).put("name", name).put("items", items)
    }
}

// The catalog file is sealed with a random AES-GCM data key; that key is itself sealed by a non-exportable
// Android Keystore key. Large catalogs then decrypt in process instead of streaming through the keystore.
// The file lives in no-backup storage and is never part of a device backup.
class CatalogStore(context: Context) {
    private val file = File(context.noBackupFilesDir, "library.encrypted")
    private val alias = "airwave-private-catalog"

    fun read(): ByteArray? {
        if (!file.exists()) return null
        val bytes = file.readBytes()
        if (bytes.size < HEADER || bytes[0] != VERSION) throw IOException("Unknown catalog format")
        val unwrap = Cipher.getInstance(GCM)
        unwrap.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, bytes, 1, 12))
        val dataKey = SecretKeySpec(unwrap.doFinal(bytes, 13, 48), "AES")
        val open = Cipher.getInstance(GCM)
        open.init(Cipher.DECRYPT_MODE, dataKey, GCMParameterSpec(128, bytes, 61, 12))
        return open.doFinal(bytes, HEADER, bytes.size - HEADER)
    }

    fun write(data: ByteArray) {
        val raw = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val wrap = Cipher.getInstance(GCM)
        wrap.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val wrapped = wrap.doFinal(raw)
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val seal = Cipher.getInstance(GCM)
        seal.init(Cipher.ENCRYPT_MODE, SecretKeySpec(raw, "AES"), GCMParameterSpec(128, iv))
        val sealed = seal.doFinal(data)
        raw.fill(0)
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.outputStream().use { out -> out.write(byteArrayOf(VERSION)); out.write(wrap.iv); out.write(wrapped); out.write(iv); out.write(sealed) }
        if (!temp.renameTo(file)) { temp.delete(); throw IOException("Could not save the library") }
    }

    private fun wrappingKey(): SecretKey {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keys.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return generator.generateKey()
    }

    private companion object {
        const val GCM = "AES/GCM/NoPadding"
        const val VERSION: Byte = 1
        // version, wrap IV (12), wrapped key (32 + 16 tag), data IV (12)
        const val HEADER = 1 + 12 + 48 + 12
    }
}
