// 3 October 2026, 19:42 CEST: re-read immutable project mapping and independently restore selected archived sources.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {createAssetsService,hashLocalFile} from '../../ZenRayProgress/scripts/AssetsService.mjs';
import {requestAssets,config} from '../../ZenRayProgress/scripts/Assets/BridgeClient.mjs';
const root='/Users/zenray/.claude/tmp/tmp-zenray-dictate';
const exec=promisify(execFile);
const token=(await exec('gh',['auth','token'])).stdout.trim();
const repository='matthieuhuguet/zenray-data';
const headers={Authorization:`Bearer ${token}`,Accept:'application/vnd.github+json','User-Agent':'zenray-dictate-verification'};
async function immutable(file){
 const response=await fetch(`https://api.github.com/repos/${repository}/contents/${file}`,{headers});
 const metadata=await response.json(); if(!response.ok||!metadata.sha)throw new Error(`Cloud metadata unavailable: ${response.status}`);
 const blobResponse=await fetch(`https://api.github.com/repos/${repository}/git/blobs/${metadata.sha}`,{headers});
 const blob=await blobResponse.json(); if(!blobResponse.ok||blob.sha!==metadata.sha||blob.encoding!=='base64')throw new Error('Immutable blob unavailable');
 return {sha:metadata.sha,text:Buffer.from(blob.content,'base64').toString('utf8')};
}
const live=await requestAssets({action:'inventory',projectId:'zenray-dictate'});
if(live.project.sync.pendingCount!==0)throw new Error('Current project files still require archiving');
await requestAssets({action:'publish',projectId:'zenray-dictate'});
const workspace=await immutable('pages/ZenRayAssets/zenray-dictate/.workspace.json');
const snapshot=JSON.parse(workspace.text);
const catalogue=await immutable('pages/.zr-assets-workspaces.json');
const registry=JSON.parse(catalogue.text);
const context=await immutable('pages/ZenRayAssets/zenray-dictate/.context.md');
if(!registry.projects.some(p=>p.id==='zenray-dictate')||!context.text.includes('zenray-dictate'))throw new Error('Project missing from cloud mapping');
const cloudPaths=snapshot.sources.map(s=>s.localPath).filter(Boolean);if(cloudPaths.length)throw new Error('Local source paths leaked into mapping');
const state=JSON.parse(await readFile(`${config.storage.stateDir}/Project-zenray-dictate.json`,'utf8'));
const selected=['application:Sources/ZenRayDictate/GeminiWebTranscriber.swift','application:Sources/ZenRayDictate/Resources/GeminiBridge.js','application:ZenRayDictate.app/Contents/MacOS/ZenRayDictate','project-notes:FEEDBACK.md','library:Library.json'];
const isolated=structuredClone(config);isolated.storage.stateDir=`${root}/CloudVerification/State`;isolated.projects=[];
const service=await createAssetsService({config:isolated});
const restored=[];
try{
 for(const id of selected){const proof=state.backups[id];if(!proof)throw new Error(`Missing archive: ${id}`);const destination=`${root}/CloudVerification/Restored/${proof.sourceId}`;const file=await service.restoreOriginal(proof,destination,{},new AbortController().signal);const sha256=await hashLocalFile(file);if(sha256!==proof.sha256)throw new Error('Restore hash mismatch');restored.push({id,size:proof.size,sha256});}
}finally{await service.close();}
const proof={date:'3 October 2026',projectId:snapshot.id,count:live.project.sync.count,backedUpCount:live.project.sync.backedUpCount,pendingCount:0,workspaceBlob:workspace.sha,registryBlob:catalogue.sha,contextBlob:context.sha,mappedSourceIDs:snapshot.sources.map(s=>s.id),restored};
await writeFile(`${root}/CloudMappingProof.json`,JSON.stringify(proof,null,2)+'\n');console.log(JSON.stringify(proof));
