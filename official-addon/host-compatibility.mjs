// Native runtime independently checks this same exact version/build/UUID matrix.
export const inspectedHosts = Object.freeze([
  Object.freeze({version:'1.0.2',build:'67',uuid:'eeea85e54114313cb65173c90a6b5d3c'}),
  Object.freeze({version:'1.0.4',build:'195',uuid:'261c8e78f9553d7d85f713b9082972cf'}),
  Object.freeze({version:'1.0.5',build:'201',uuid:'748fd301da603095a2449bd0558faca5'}),
  // 1.0.7/230：本机解包新砸壳 Runner 的 LC_UUID 原始字节序验证，与上游 audit 一致。
  Object.freeze({version:'1.0.7',build:'230',uuid:'410defdbf93739eaacf2f616abff9d0b'}),
  // 1.0.10/258：第三方砸壳（净化版）已按官方加密包逐文件审计——二进制尺寸全等、
  // 无注入 dylib、域名全部可认领；Runner LC_UUID 本机解出并与官方加密包互证。
  Object.freeze({version:'1.0.10',build:'258',uuid:'f5efecca88d93bb6a53ddf6acdfcc928'}),
]);
export function inspectedHost(info, uuid) {
  if(info.CFBundleIdentifier!=='com.rayneo.venus.pub'||info.CFBundleExecutable!=='Runner')return null;
  return inspectedHosts.find(h=>h.version===info.CFBundleShortVersionString&&h.build===String(info.CFBundleVersion)&&h.uuid===uuid)??null;
}
