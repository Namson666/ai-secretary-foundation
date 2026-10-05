import {getWord} from '../content.js';
import {icon,go,escape} from '../ui.js';
import {coach,mountCoach,handleCoachAction,leaveCoach} from '../coach-interactions.js';
export {coach};
export const mount=mountCoach;
export const handleAction=handleCoachAction;
export const leave=leaveCoach;
const css=new URL('../coach.css',import.meta.url).href;
const portrait=new URL('../../assets/mentor-preview.webp',import.meta.url).href;
const glyph=(path)=>`<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${path}"/></svg>`;
const video=()=>glyph('M3 6h12v12H3ZM15 10l6-4v12l-6-4');
const phone=()=>glyph('M5 14c4-4 10-4 14 0l2 3-4 2-2-3H9l-2 3-4-2Z');
const keyboard=()=>glyph('M2 6h20v12H2Zm4 4h.1m4 0h.1m4 0h.1m4 0h.1M7 14h10');
const bars=(count)=>Array.from({length:count},(_,i)=>`<i style="--bar:${i%5}"></i>`).join('');
function avatar(extra='') {
 return `<div class="coach-portrait ${extra}" aria-hidden="true"><img src="${portrait}" alt="" draggable="false"></div>`;
}
function callView() {
 return `<div class="coach-call-overlay ${coach.expanded?'':'coach-call-embedded'}" data-coach-call role="${coach.expanded?'dialog':'region'}" ${coach.expanded?'aria-modal="true"':''} aria-labelledby="coach-call-title" tabindex="-1">${avatar('coach-portrait-call')}<div class="coach-call-shade"></div>
 <header class="coach-call-top"><div><span class="coach-call-badge">交互预览 · 模拟通话</span><h1 id="coach-call-title">和 Emma 面对面</h1><span class="coach-call-timer" data-call-timer>00:00</span></div><button class="coach-round coach-scale" data-action="${coach.expanded?'coach-shrink':'coach-expand'}" aria-label="${coach.expanded?'收起全屏，保留模拟通话':'展开全屏模拟通话'}">${glyph('m8 3 0 5H3m18 0h-5V3M3 16h5v5m8 0v-5h5')}</button></header>
 <div class="coach-call-bottom"><div class="coach-call-caption" aria-live="polite"><span data-call-status>Emma 正在说</span><p data-call-subtitle>Hello! Ready for a little English practice?</p><small data-call-translation>你好！准备好练一小会儿英语了吗？</small></div><div class="coach-call-wave" aria-hidden="true">${bars(17)}</div>
 <div class="coach-call-buttons"><div><button class="coach-round" data-action="coach-speaker" aria-label="${coach.speaker?'关闭':'开启'}扬声器" aria-pressed="${coach.speaker}">${icon('audio',24)}</button><span data-speaker-label>${coach.speaker?'扬声器':'声音关闭'}</span></div><div><button class="coach-round coach-hangup" data-action="coach-hangup" aria-label="结束模拟通话">${phone()}</button><span>结束</span></div><div><button class="coach-round ${coach.muted?'is-muted':''}" data-action="coach-mute" aria-label="${coach.muted?'取消':'开启'}麦克风静音" aria-pressed="${coach.muted}">${icon('mic',24)}<i class="coach-mute-slash" aria-hidden="true"></i></button><span data-mute-label>${coach.muted?'已静音':'静音'}</span></div></div>
 <button class="coach-native-fullscreen" data-action="coach-expand">${glyph('M9 3H3v6m12-6h6v6M3 15v6h6m12-6v6h-6')} 全屏显示</button><p class="coach-call-footnote">模拟实时对话 · 无需开启摄像头或麦克风</p></div></div>`;
}
function messageView(m) {
 const user=m.type==='user';
 return `<article class="coach-message ${user?'coach-message-user':'coach-message-emma'}"><small>${user?'你':'Emma · 拾语教练'}</small>${m.format==='voice'?`<div class="coach-voice-message">${icon('audio',17)}<span class="coach-voice-bars" aria-hidden="true">▂ ▆ ▃ ▇ ▄ ▂ ▅</span><b>${Math.max(1,Math.round(m.duration||1))}″</b></div>`:''}<p>${escape(m.text)}</p>${m.operationId?`<button class="text-button" data-action="undo" data-id="${escape(m.operationId)}" ${m.undone?'disabled':''}>${m.undone?'本次收录已撤销':'撤销本次收录'}</button>`:''}</article>`;
}
export function render(state) {
 const word=getWord(state.focusWord);
 const focusChoices=[...new Set([state.focusWord,...(state.selectedWords??[])])].map(getWord);
 return `<link rel="stylesheet" href="${css}"><section class="coach-shell" data-coach-root>${coach.inCall?`${coach.expanded?'':'<header class="coach-header"><div><span class="coach-kicker">AI 语言陪练</span><h1>视频聊天</h1></div><span class="coach-preview-tag">模拟通话中</span></header>'}${callView()}`:`
 <header class="coach-header"><div><span class="coach-kicker">AI 语言陪练</span><h1>和 Emma 聊聊</h1></div><span class="coach-preview-tag">交互预览</span></header>
 <div class="coach-mode-tabs" role="group" aria-label="对话模式"><button data-action="coach-mode" data-mode="chat" aria-pressed="${coach.mode==='chat'}" class="${coach.mode==='chat'?'is-selected':''}">${icon('coach',18)} 普通对话</button><button data-action="coach-mode" data-mode="video" aria-pressed="${coach.mode==='video'}" class="${coach.mode==='video'?'is-selected':''}">${video()} 视频聊天</button></div>
 <section class="coach-avatar-stage ${coach.mode==='video'?'coach-video-preview':''}" aria-label="Emma 导师形象示例">${avatar()}<div class="coach-avatar-name"><b>Emma</b><span>你的英语陪练</span></div><span class="coach-avatar-status"><i></i> 随时可以聊</span><div class="coach-stage-bottom"><p>${coach.mode==='video'?'打开全屏，面对面练英语':'今天的进步，从一句话开始。'}</p><button class="coach-round coach-start-call" data-action="coach-call" aria-label="开始全屏模拟视频聊天">${phone()}</button></div></section>
 ${coach.mode==='video'?`<div class="coach-video-intro"><h2>就像坐在你对面</h2><p>全屏导师、双语字幕，和清晰的通话控制。<br>点击绿色通话按钮，体验模拟实时对话。</p><button class="primary full" data-action="coach-call">${video()} 开始模拟视频聊天</button><button class="text-button" data-action="coach-mode" data-mode="chat">回到普通对话</button></div>`:`
 <div class="coach-topic"><div><label for="focus-word">正在聊的词</label><span>一句话，也能变成下一次练习</span></div><select id="focus-word" aria-label="正在聊的词">${focusChoices.map(w=>`<option value="${escape(w.id)}" ${w.id===state.focusWord?'selected':''}>${escape(w.word)}</option>`).join('')}</select></div>
 <div class="coach-conversation" aria-label="对话记录"><article class="coach-message coach-message-emma"><small>Emma · 拾语教练</small><p>Hi，今天也来陪你练英语。<br>我们可以聊聊 <strong>${escape(word.word)}</strong>，也可以把它留到明天练。</p><span>先试一句：“这个词明天练发音。”</span></article>${state.messages.map(messageView).join('')}</div>
 ${state.capture?`<section class="coach-capture capture-preview"><span class="eyebrow">指令已听懂 · 对象已固定</span><h3>${escape(getWord(state.capture.wordId).word)} · 明天练发音</h3><p>切换正在聊的词，也不会改变本次复习对象。</p><div><button class="primary compact" data-action="save-capture">加入演示复习点</button><button class="text-button" data-action="cancel-capture">取消</button></div></section>`:''}
 <div class="coach-suggestions"><button data-action="coach-progress">${icon('bolt',15)} 看看学习进度</button>${go('去计划安排 ↗','plan','')}</div>
 <div class="coach-composer"><div class="coach-record-feedback" data-record-feedback hidden role="status"><div class="coach-record-wave" aria-hidden="true">${bars(13)}</div><strong data-record-clock>00:00</strong><span data-record-hint>松开发送 · 上滑取消</span></div><div class="coach-compose-row"><button class="coach-input-toggle" data-action="coach-input" aria-label="${coach.input==='voice'?'切换文字输入':'切换语音输入'}">${coach.input==='voice'?keyboard():icon('mic',22)}</button>
 ${coach.input==='voice'?`<button class="coach-hold-button" data-hold-to-talk aria-label="按住模拟说话，松开发送，上滑取消。也可按住空格键" aria-describedby="coach-input-note">${icon('mic',18)}<span data-hold-label>按住说话</span></button>`:`<form id="coach-form" class="coach-text-form"><label class="sr-only" for="coach-input">给教练的文字指令</label><input id="coach-input" name="message" placeholder="聊聊今天，或安排复习…" maxlength="500" autocomplete="off"><button class="coach-send" aria-label="发送文字指令">${icon('arrow',20)}</button></form>`}</div><p id="coach-input-note" class="coach-input-note">${coach.input==='voice'?'模拟语音：“这个词明天练发音” · 按住空格也可以':'输入如“ship 明天练发音”，教练会帮你收录'}</p>${coach.input==='voice'?'<button class="coach-accessible-send text-button" data-action="coach-demo-voice">直接发送这句模拟语音</button>':''}</div>`}<p class="coach-simulation-note">形象示例 · 模拟对话，不录音或上传音频</p>`}</section>`;
}
