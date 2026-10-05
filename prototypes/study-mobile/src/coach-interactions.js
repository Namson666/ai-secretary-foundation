import {getWord} from './content.js';

// Ephemeral interaction state: recordings and call timers never enter the demo repository.
export const coach={mode:'chat',input:'voice',inCall:false,expanded:true,speaker:true,muted:false,startedAt:0};
let current=null;
const captions=[
 ['Hello! Ready for a little English practice?','你好！准备好练一小会儿英语了吗？'],
 ['Let’s start with a word you learned today.','从今天学到的一个词开始吧。'],
 ['Take your time. Small steps still count.','慢慢来，每一小步都算数。'],
 ['You can save this word for tomorrow’s practice.','也可以把这个词留到明天练习。'],
];
const clock=seconds=>`${String(Math.floor(seconds/60)).padStart(2,'0')}:${String(seconds%60).padStart(2,'0')}`;
function stopSpeech(){if('speechSynthesis' in globalThis)globalThis.speechSynthesis.cancel();}
function exitNativeFullscreen(){if(document.fullscreenElement?.matches('[data-coach-call]'))document.exitFullscreen?.().catch(()=>{});}
export function leaveCoach(){current?.cancelRecording();current?.stopCallTimers();coach.inCall=false;coach.expanded=true;coach.startedAt=0;coach.muted=false;stopSpeech();exitNativeFullscreen();}

function sendVoice(context,wordId,duration=1){
 context.commands.capture(wordId);
 context.store.update(s=>s.messages.push({type:'user',format:'voice',duration,wordId,text:`这个词明天练发音。（模拟语音，指向 ${getWord(wordId).word}）`}));
 context.render();
 context.toast('模拟语音已发送，复习对象已固定。');
}
function endCall(context){
 if(!coach.inCall)return;
 leaveCoach();coach.mode='chat';context.render();context.toast('模拟通话已结束。');
 document.querySelector('[data-action="coach-call"]')?.focus({preventScroll:true});
}
export function handleCoachAction(action,button,context=current?.context){
 if(!action?.startsWith('coach-')||!context)return false;
 switch(action){
 case 'coach-mode':
  if(!['chat','video'].includes(button.dataset.mode))return false;
  current?.cancelRecording();leaveCoach();coach.mode=button.dataset.mode;context.render();break;
 case 'coach-input':
  current?.cancelRecording();coach.input=coach.input==='voice'?'text':'voice';context.render();
  document.querySelector(coach.input==='text'?'#coach-input':'[data-hold-to-talk]')?.focus({preventScroll:true});break;
 case 'coach-demo-voice':
  if(!coach.inCall&&!current?.recording)sendVoice(context,context.store.get().focusWord);break;
 case 'coach-call':
  current?.cancelRecording();coach.inCall=true;coach.expanded=true;coach.startedAt=Date.now();coach.muted=false;
  coach.speaker=!context.store.get().quiet;context.render();break;
 case 'coach-hangup':endCall(context);break;
 case 'coach-shrink':
  if(coach.inCall){coach.expanded=false;exitNativeFullscreen();context.render();}
  break;
 case 'coach-speaker':
  if(!coach.inCall)break;
  if(context.store.get().quiet&&!coach.speaker){context.toast('全局静音模式已开启，可继续阅读通话字幕。');break;}
  coach.speaker=!coach.speaker;stopSpeech();current?.syncCallControls();
  if(coach.speaker)current?.playCaption();break;
 case 'coach-mute':
  if(!coach.inCall)break;
  coach.muted=!coach.muted;current?.cancelRecording();current?.syncCallControls();break;
 case 'coach-expand':{
  if(!coach.inCall)break;
  if(!coach.expanded){coach.expanded=true;context.render();}
  const requestedSession=current;
  const overlay=current?.root.querySelector('[data-coach-call]');
  if(!overlay?.requestFullscreen){context.toast('当前浏览器已使用铺满屏幕的通话视图。');break;}
  overlay.requestFullscreen().catch(()=>{if(current===requestedSession&&coach.inCall)context.toast('浏览器未开启系统全屏，通话视图仍铺满屏幕。');});break;
 }
 default:return false;
 }
 return true;
}

export function mountCoach(root,context){
 const scope=root.querySelector('[data-coach-root]');if(!scope)return ()=>{};
 const listeners=[];const timers=new Set();let disposed=false;let recording=null;let recordTimer=null;let nativeEntered=false;let lastCaption=-1;
 const device=root.closest('.device');const overlay=scope.querySelector('[data-coach-call]');
 device?.classList.toggle('coach-call-active',Boolean(overlay&&coach.expanded));
 const inertNodes=[];
 const session={root:scope,context,cancelRecording,syncCallControls,playCaption,stopCallTimers(){for(const id of timers)clearInterval(id);timers.clear();},get recording(){return recording;}};current=session;
 function listen(node,type,callback,options){node?.addEventListener(type,callback,options);listeners.push(()=>node?.removeEventListener(type,callback,options));}
 function interval(callback,ms){const id=setInterval(()=>{if(!disposed)callback();},ms);timers.add(id);return id;}
 function clearTimer(id){clearInterval(id);timers.delete(id);}
 function setText(selector,value){const el=scope.querySelector(selector);if(el)el.textContent=value;}
 function cancelRecording(){
  const previous=recording;recording=null;
  if(recordTimer!==null){clearTimer(recordTimer);recordTimer=null;}
  const hold=scope.querySelector('[data-hold-to-talk]');
  if(previous&&previous.pointerId!==null&&hold?.hasPointerCapture?.(previous.pointerId))hold.releasePointerCapture(previous.pointerId);
  scope.classList.remove('is-recording','is-record-cancel');
  const feedback=scope.querySelector('[data-record-feedback]');if(feedback)feedback.hidden=true;
  setText('[data-hold-label]','按住说话');
 }
 function beginRecording(event,keyboard=false){
  if(disposed||recording||coach.inCall||coach.input!=='voice')return;
  if(!keyboard&&(!event.isPrimary||event.button!==0))return;
  event.preventDefault();
  recording={pointerId:keyboard?null:event.pointerId,startY:keyboard?0:event.clientY,startedAt:Date.now(),wordId:context.store.get().focusWord,cancelled:false,keyboard};
  if(!keyboard)event.currentTarget.setPointerCapture?.(event.pointerId);
  scope.classList.add('is-recording');scope.querySelector('[data-record-feedback]').hidden=false;
  setText('[data-record-clock]','00:00');setText('[data-record-hint]','松开发送 · 上滑取消');setText('[data-hold-label]','松开发送');
  recordTimer=interval(()=>{
   if(!recording)return;
   const seconds=Math.floor((Date.now()-recording.startedAt)/1000);setText('[data-record-clock]',clock(seconds));
   if(seconds>=30){cancelRecording();context.toast('模拟按住时间过长，本轮已取消。');}
  },100);
 }
 function finishRecording(event,keyboard=false){
  if(!recording||recording.keyboard!==keyboard||(!keyboard&&event.pointerId!==recording.pointerId))return;
  event.preventDefault();const captured=recording;const duration=(Date.now()-captured.startedAt)/1000;
  cancelRecording();
  if(captured.cancelled){context.toast('本轮模拟语音已取消。');return;}
  if(duration<.25){context.toast('请按住说话，再松开发送。');return;}
  sendVoice(context,captured.wordId,duration);
 }
 const hold=scope.querySelector('[data-hold-to-talk]');
 listen(hold,'pointerdown',event=>beginRecording(event));
 listen(hold,'pointermove',event=>{
  if(!recording||recording.keyboard||event.pointerId!==recording.pointerId)return;
  recording.cancelled=recording.startY-event.clientY>65;
  scope.classList.toggle('is-record-cancel',recording.cancelled);
  setText('[data-record-hint]',recording.cancelled?'松开取消 · 下移继续':'松开发送 · 上滑取消');
  setText('[data-hold-label]',recording.cancelled?'松开取消':'松开发送');
  const bounds=hold.getBoundingClientRect();
  if(event.clientX<bounds.left-70||event.clientX>bounds.right+70||event.clientY>bounds.bottom+70)cancelRecording();
 });
 listen(hold,'pointerup',event=>finishRecording(event));
 listen(hold,'pointercancel',cancelRecording);
 listen(hold,'lostpointercapture',cancelRecording);
 listen(hold,'pointerleave',event=>{if(event.pointerType==='mouse'&&!hold.hasPointerCapture?.(event.pointerId))cancelRecording();});
 listen(hold,'keydown',event=>{if([' ','Enter'].includes(event.key)&&!event.repeat)beginRecording(event,true);});
 listen(hold,'keyup',event=>{if([' ','Enter'].includes(event.key))finishRecording(event,true);});
 listen(hold,'blur',cancelRecording);
 listen(window,'blur',cancelRecording);
 listen(document,'visibilitychange',()=>{if(document.hidden)cancelRecording();});
 listen(window,'keydown',event=>{
  if(event.key==='Escape'){
   if(recording){event.preventDefault();cancelRecording();context.toast('本轮模拟语音已取消。');}
   else if(coach.inCall&&coach.expanded){event.preventDefault();handleCoachAction('coach-shrink',null,context);}
  }
  if(overlay&&coach.expanded&&event.key==='Tab'){
   const buttons=[...overlay.querySelectorAll('button:not(:disabled)')];const first=buttons[0];const last=buttons.at(-1);
   if(event.shiftKey&&document.activeElement===first){event.preventDefault();last?.focus();}
   else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first?.focus();}
  }
 });
 listen(document,'fullscreenchange',()=>{
  if(document.fullscreenElement===overlay)nativeEntered=true;
  else if(nativeEntered&&coach.inCall){nativeEntered=false;handleCoachAction('coach-shrink',null,context);}
 });
 function syncCallControls(){
  const speaker=scope.querySelector('[data-action="coach-speaker"]');const mute=scope.querySelector('[data-action="coach-mute"]');
  speaker?.setAttribute('aria-pressed',String(coach.speaker));speaker?.setAttribute('aria-label',`${coach.speaker?'关闭':'开启'}扬声器`);
  speaker?.classList.toggle('is-muted',!coach.speaker);
  mute?.setAttribute('aria-pressed',String(coach.muted));mute?.setAttribute('aria-label',`${coach.muted?'取消':'开启'}麦克风静音`);mute?.classList.toggle('is-muted',coach.muted);
  setText('[data-speaker-label]',coach.speaker?'扬声器':'声音关闭');setText('[data-mute-label]',coach.muted?'已静音':'静音');
  setText('[data-call-status]',coach.muted?'麦克风已静音 · Emma 正在说':'Emma 正在说');
 }
 function playCaption(){
  if(disposed||!coach.inCall||!coach.speaker||context.store.get().quiet||!('speechSynthesis' in globalThis))return;
  stopSpeech();const text=captions[Math.max(0,lastCaption)][0];
  const utterance=new SpeechSynthesisUtterance(text);utterance.lang='en-US';utterance.rate=.86;globalThis.speechSynthesis.speak(utterance);
 }
 if(overlay){
  if(coach.expanded){
  document.body.classList.add('coach-in-call');device?.classList.add('coach-call-active');
  for(const node of [device?.querySelector('#navigation'),device?.querySelector('.phone-status'),device?.querySelector('.preview-ribbon'),document.querySelector('.preview-note'),document.querySelector('#reset-preview')]){
   if(node&&!node.contains(overlay)){inertNodes.push([node,node.inert]);node.inert=true;}
  }
  }
  overlay.querySelector('[data-action="coach-hangup"]')?.focus({preventScroll:true});syncCallControls();
  const tick=()=>{
   const seconds=Math.floor((Date.now()-coach.startedAt)/1000);setText('[data-call-timer]',clock(seconds));
   const index=Math.floor(seconds/7)%captions.length;
   if(index!==lastCaption){lastCaption=index;setText('[data-call-subtitle]',captions[index][0]);setText('[data-call-translation]',captions[index][1]);playCaption();}
  };
  tick();interval(tick,1000);
 }
 return ()=>{
  if(disposed)return;disposed=true;cancelRecording();for(const id of timers)clearInterval(id);timers.clear();for(const remove of listeners)remove();
  for(const [node,wasInert] of inertNodes)node.inert=wasInert;
  document.body.classList.remove('coach-in-call');device?.classList.remove('coach-call-active');stopSpeech();
  if(current===session)current=null;
  // Rendering remounts synchronously; leaving the page does not. Only the latter ends the call.
  queueMicrotask(()=>{if(!current)leaveCoach();});
 };
}
