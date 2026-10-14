#!/usr/bin/env node
// 本机"手机侧观察接口"模拟器：在 127.0.0.1:18766 上扮演 Turbo IO 的
// /snapshot 端点，供 display-observer 做无设备联调。仅演示数据。
// 用法：node display-observer/mock-phone.mjs
// 浏览器打开 http://127.0.0.1:8790/ ，在「USB 数据源」里输入任意 32 位
// 十六进制令牌（如 a1b2c3d4e5f60718293a4b5c6d7e8f90）点连接即可。
import http from 'node:http';

const PORT = 18766;
const nowSec = () => Date.now() / 1000;
const menuNames = ['录音','实时字幕','实时提示','待办','提词器','全天智记','勿扰模式'];
const question = '帮我看看今天下午的日程安排';
const answer = '今天下午有两场安排：14:00–15:30 项目复盘会议（503 室），16:00–16:30 视觉设计评审（线上）。建议提前十分钟到场。';

const state = { scene: 0, step: 0, events: [{kind:'connection',at:nowSec(),detail:'模拟器已启动（本机演示数据）'}] };
function pushEvent(kind, detail) {
  state.events.push({kind, at: nowSec(), detail});
  if (state.events.length > 40) state.events.splice(0, state.events.length - 40);
}

// 场景循环：首页 → 菜单逐项 → 一轮问答（聆听→生成→展示）→ 回首页
function buildSnapshot() {
  const at = nowSec();
  const base = {version:1, connected:true, session:'mock-local', sampledAt:at,
    includesText:false, phase:'idle', page:{scene:0,at,action:0}, question:'', answer:'',
    events:state.events};
  if (state.scene === 1) { // 菜单浏览：scene 1 = 菜单选中第 index 项（1 起）
    const index = (state.step % 7) + 1;
    base.page = {scene:1, at, action:0, index};
    return base;
  }
  if (state.scene === 2) { // 问答：按阶段推进，文字逐步出现
    base.includesText = true;
    if (state.step === 0) { base.phase = 'recording';  base.question = question.slice(0, 8); }
    if (state.step === 1) { base.phase = 'recording';  base.question = question; pushEvent('received','眼镜 → App：唤醒并采集提问'); }
    if (state.step === 2) { base.phase = 'processing'; base.question = question; }
    if (state.step >= 3) {
      base.phase = 'displaying';
      base.question = question;
      base.answer = answer.slice(0, Math.min(answer.length, (state.step - 2) * 18));
      if (state.step - 2 >= Math.ceil(answer.length / 18)) pushEvent('submitted','App → SDK · 已提交回答');
    }
    return base;
  }
  pushEvent('received','眼镜 → App：回到首页仪表盘');
  return base;
}

setInterval(() => {
  state.step++;
  if (state.scene === 0 && state.step >= 2) { state.scene = 1; state.step = 0; }
  else if (state.scene === 1 && state.step >= 7) { state.scene = 2; state.step = 0; }
  else if (state.scene === 2 && state.step >= 8) { state.scene = 0; state.step = 0; }
}, 2500);

const sceneName = () => ['首页仪表盘','菜单浏览','语音问答'][state.scene];
const server = http.createServer((req, res) => {
  const auth = req.headers.authorization || '';
  const ok = req.method === 'GET' && req.url === '/snapshot' && /^Bearer [a-f0-9]{32}$/i.test(auth);
  if (!ok) { res.writeHead(req.headers.authorization ? 403 : 401, {'Content-Type':'application/json'}); res.end(JSON.stringify({error:'token'})); return; }
  const snapshot = buildSnapshot();
  res.writeHead(200, {'Content-Type':'application/json; charset=utf-8', 'Cache-Control':'no-store'});
  res.end(JSON.stringify(snapshot));
  process.stdout.write(`[mock] ${sceneName()} · phase=${snapshot.phase} · q=${snapshot.question.length}字 a=${snapshot.answer.length}字\n`);
});
server.listen(PORT, '127.0.0.1', () => process.stdout.write(
  `手机侧模拟器已就绪 http://127.0.0.1:${PORT}/snapshot\n` +
  `观察台连接令牌可用：a1b2c3d4e5f60718293a4b5c6d7e8f90\n`));
for (const s of ['SIGINT','SIGTERM']) process.on(s, () => { server.close(); server.closeAllConnections(); });
