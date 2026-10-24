const {spawnSync}=require('node:child_process');const path=require('node:path');const fs=require('node:fs');
const root=path.resolve(__dirname,'..');
const profile=process.env.AIRWAVE_CERT_PROFILE;
if(!profile){console.error('Set AIRWAVE_CERT_PROFILE to your Samsung certificate profile name. No unsigned widget will be labelled installable. See README.md.');process.exit(1);}
fs.mkdirSync(path.join(root,'dist'),{recursive:true});
const p=spawnSync('tizen',['package','-t','wgt','-s',profile,'-o',path.join(root,'dist'),'--',path.join(root,'app')],{stdio:'inherit'});
if(p.error){console.error('Tizen CLI is unavailable. Install Tizen Studio with the Samsung TV extension and configure your signing profile.');process.exit(1);}process.exit(p.status||0);
