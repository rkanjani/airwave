import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
}

// The shared interface is staged from app/ through the same allowlist as the web and Samsung releases.
val repoRoot = rootDir.resolve("../..").canonicalFile
val webAssets = layout.buildDirectory.dir("generated/airwave/assets")
val stageWeb = tasks.register<Exec>("stageWeb") {
    val output = webAssets.get().asFile
    inputs.dir(repoRoot.resolve("app"))
    inputs.file(repoRoot.resolve("scripts/runtime-files.cjs"))
    outputs.dir(output)
    doFirst { output.deleteRecursively() }
    commandLine("node", "-e", "require(process.argv[1]).stageRuntime(process.argv[2])",
        repoRoot.resolve("scripts/runtime-files.cjs").path, output.resolve("app").path)
}

android {
    namespace = "app.airwave.android"
    compileSdk = 37
    defaultConfig {
        applicationId = "app.airwave.android"
        minSdk = 24
        targetSdk = 36
        versionCode = 200
        versionName = "0.2.0"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    buildFeatures {
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["main"].assets.directories.add(webAssets.get().asFile.path)
}

tasks.named("preBuild") { dependsOn(stageWeb) }

dependencies {
    implementation("androidx.activity:activity-ktx:1.13.0")
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.webkit:webkit:1.18.0")
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.11.1")
    implementation("androidx.media3:media3-ui:1.11.1")
    testImplementation("junit:junit:4.13.2")
}
