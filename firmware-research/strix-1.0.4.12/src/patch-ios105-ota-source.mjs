// Offline, opt-in source-routing experiment. Does not install, serve or flash.
// Preserve Dart string size AND cached noncryptographic hash, so the existing
// canonical hash-table placement is not changed. Not a firmware MD5 bypass.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {pathToFileURL} from 'node:url';
// 两条 gray/upgrade 路径在 1.0.5(201) 与 1.0.7(230) 快照中同文、同 Dart 缓存哈希，
// 因此 makeRoute 的确定性替换串也相同；仅快照整体 SHA 与落点偏移不同。
// 两个输入 SHA 均与砸壳归档审计值逐字节核对（1.0.7 App 快照 = 041dc97a…）。
export const originalSHAs={
  'f5691eb07c1eaa4270de24ad1a0b09829cb35c2d22a5fab16b818aa519c8c23a':'1.0.5/201',
  '041dc97ad3a864ac322e92a49d3b1ebbd466d371dc427591b0b82c8c56b5090d':'1.0.7/230',
  // 1.0.10/258 净化砸壳快照：两条 gray/upgrade 串同文同缓存哈希（makeRoute 同替换串），
  // 偏移 39880448/30866352 已本机核对（记录头 hash+len 与 patch() 断言逐字节通过）。
  '34e78ee05e607490402b581841b2e01ab3a4abe6679afc131ac7581127aca41c':'1.0.10/258',
};
export const originalSHA=Object.keys(originalSHAs)[0];
export const originals=['/xrlauncherapi/v1/signApi/gray/upgrade','/xrlauncherhwapi/v1/signApi/gray/upgrade'];
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
const assert=(v,s)=>{if(!v)throw Error(s);};
const combine=(h,c)=>{h=(h+c)>>>0;h=Math.imul(h,1025)>>>0;return (h^(h>>>6))>>>0;};
function accumulate(s){let h=0;for(const c of Buffer.from(s))h=combine(h,c);return h;}
function finalize(h){h=Math.imul(h,9)>>>0;h=(h^(h>>>11))>>>0;h=Math.imul(h,32769)>>>0;return (h&0x3fffffff)||1;}
export const stringHash=s=>finalize(accumulate(s));
function inverseOdd(n){let x=1n;for(let i=0;i<6;i++)x=(x*(2n-BigInt(n)*x))&0xffffffffn;return Number(x);}
function undoXor(n,shift){let x=n;for(let s=shift;s<32;s+=shift)x^=n>>>s;return x>>>0;}
const inv1025=inverseOdd(1025),inv9=inverseOdd(9),inv32769=inverseOdd(32769);
const uncombine=(h,c)=>(Math.imul(undoXor(h,6),inv1025)-c)>>>0;
const unfinalize=h=>Math.imul(undoXor(Math.imul(h,inv32769)>>>0,11),inv9)>>>0;
const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
export function makeRoute(original){
  const base='http://127.0.0.1:18794/g/';
  const prefix=base+'x'.repeat(Buffer.byteLength(original)-base.length-6);
  const target=stringHash(original);assert(target>1,'Unsupported degenerate hash');
  const forward=new Map(),initial=accumulate(prefix);
  for(let a=0;a<64;a++)for(let b=0;b<64;b++)for(let c=0;c<64;c++){
    const h=combine(combine(combine(initial,alphabet.charCodeAt(a)),alphabet.charCodeAt(b)),alphabet.charCodeAt(c));
    if(!forward.has(h))forward.set(h,a*4096+b*64+c);
  }
  for(let hi=0;hi<4;hi++){
    const end=unfinalize((target+hi*0x40000000)>>>0);
    for(let c=0;c<64;c++)for(let b=0;b<64;b++)for(let a=0;a<64;a++){
      const h=uncombine(uncombine(uncombine(end,alphabet.charCodeAt(c)),alphabet.charCodeAt(b)),alphabet.charCodeAt(a));
      const first=forward.get(h);if(first===undefined)continue;
      const result=prefix+alphabet[first>>>12]+alphabet[(first>>>6)&63]+alphabet[first&63]+alphabet[a]+alphabet[b]+alphabet[c];
      assert(result.length===original.length&&stringHash(result)===target,'Hash construction failed');
      return result;
    }
  }
  throw Error('No compatible route found; do not patch');
}
export function patch(input){
  const edition=originalSHAs[sha(input)];
  assert(edition,'Wrong input: only original App.framework 1.0.5/201, 1.0.7/230 or 1.0.10/258');
  const output=Buffer.from(input),changes=[];
  for(const original of originals){
    const offset=input.indexOf(original);assert(offset>=16&&input.indexOf(original,offset+1)===-1,'Path not unique');
    assert(input.readBigUInt64LE(offset-8)===BigInt(original.length*2),'Unexpected Dart string length');
    assert(input.readUInt32LE(offset-12)===stringHash(original),'Unexpected cached Dart hash');
    const replacement=makeRoute(original);output.write(replacement,offset,'ascii');
    assert(output.subarray(offset-16,offset).equals(input.subarray(offset-16,offset)),'Object header changed');
    changes.push({offset,bytes:original.length,original,replacement,stringHash:stringHash(original)});
  }
  for(let i=0;i<input.length;i++)if(input[i]!==output[i])assert(changes.some(c=>i>=c.offset&&i<c.offset+c.bytes),'Unexpected patch byte');
  return {output,report:{inputSHA:sha(input),edition,outputSHA:sha(output),bytes:output.length,changes,
    instructionsChanged:false,objectHeadersChanged:false,deviceIO:false,runtimeValidated:false,
    note:'Requires explicit local loopback feed, re-signing and real host acceptance. Does not create an installable app by itself.'}};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
  const [source,destination]=process.argv.slice(2);assert(source&&destination,'Usage: ORIGINAL_APP NEW_OUTPUT_DIRECTORY');
  assert(!fs.existsSync(destination),'Output exists');const {output,report}=patch(fs.readFileSync(source));
  fs.mkdirSync(destination,{mode:0o700});fs.writeFileSync(path.join(destination,'App'),output,{flag:'wx',mode:0o600});
  fs.writeFileSync(path.join(destination,'report.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify(report,null,2));
}
