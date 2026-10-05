import {store} from './state.js';
import {commands} from './services.js';
import {words,getWord} from './content.js';
import {canRateIndependent} from './learning.js';
import {resolveReviewTarget} from './agent-intent.js';
import {icon,toast,escape} from './ui.js';
import * as home from './pages/home.js';
import * as learn from './pages/learn.js';
import * as review from './pages/review.js';
import * as plan from './pages/plan.js';
import * as coach from './pages/coach.js';
import * as library from './pages/library.js';
import * as profile from './pages/profile.js';
import * as exam from './pages/exam.js';
const pages={home,learn,review,plan,coach,library,profile,exam};
const navigation=[['home','今日'],['review','复习'],['plan','计划'],['coach','教练'],['profile','我的']];
const app=document.querySelector('#app');
let active='home';
let playbackGeneration=0;
let practiceItem=null;
function render({focus=false}={}) {
 active=location.hash.slice(1);if(active==='practice'&&!practiceItem)active='review';if(!pages[active])active='home';
 app.innerHTML=pages[active].render(store.get());
 document.querySelector('#navigation').innerHTML=navigation.map(([route,label])=>`<button data-route="${route}" ${active===route?'aria-current="page"':''}>${icon(route==='profile'?'user':route)}<span>${label}</span></button>`).join('');
 if(focus){app.scrollTop=0;app.focus({preventScroll:true});}
}
function route(name) {if(name&&pages[name]){if(active===name)render({focus:true});else location.hash=name;}}
function receipt(result,success) {toast(result.error??result.message??success);render();}
function next() {learn.session.reviewId=null;learn.session.index=(learn.session.index+1)%words.length;learn.resetQuestion();}
function capture(wordId) {commands.capture(wordId);store.update(s=>s.messages.push({type:'user',text:`“这个词明天练发音。”（模拟语音，指向 ${getWord(wordId).word}）`}));route('coach');render();}
function answer(result,answerText='') {learn.session.result=result;learn.session.answer=answerText;learn.session.revealed=true;render();}
function speak(text) {
 if(store.get().quiet){toast('静音模式已开启。可以阅读文本；口语任务仍待练。');return;}
 if(!('speechSynthesis' in window)){toast('本浏览器无法朗读，请阅读文本继续。');return;}
 const playback=++playbackGeneration;const generation=learn.session.generation;const mode=learn.session.mode;const expectedText=words[learn.session.index].example;speechSynthesis.cancel();const utterance=new SpeechSynthesisUtterance(text);utterance.lang='en-US';utterance.rate=.85;
 const currentWord=words[learn.session.index].id;utterance.onend=()=>{if(playback===playbackGeneration&&generation===learn.session.generation&&mode==='listen'&&text===expectedText&&active==='learn'&&learn.session.mode==='listen'&&words[learn.session.index].id===currentWord&&!learn.session.revealed){learn.session.audioPlayed=true;toast('示范播放结束，现在可以选择。');}};
 utterance.onerror=()=>toast('朗读未能播放，请阅读文本继续。');speechSynthesis.speak(utterance);toast('正在使用浏览器示范朗读');
}
const actions={
 quiet(){store.update(s=>s.quiet=!s.quiet);render();},
 'learn-mode'(b){learn.session.reviewId=null;learn.session.mode=b.dataset.mode;learn.resetQuestion();render();},
 'recall-claimed'(){if(learn.session.hinted)return;learn.session.result='self-recalled';learn.session.revealed=true;render();},
 'learn-next'(){next();render();},'learn-hint'(){learn.session.hinted=true;render();},'learn-reveal'(){learn.session.revealed=true;render();},
 'learn-rate'(b){if(b.dataset.rating!=='again'&&!canRateIndependent(learn.session))return;commands.complete(words[learn.session.index].id,'词义',learn.session.hinted?'assisted':`self-${b.dataset.rating}`);if(learn.session.reviewId){if(b.dataset.rating!=='again'&&!learn.session.hinted)commands.finishReview(learn.session.reviewId,false);learn.session.reviewId=null;route('review');}else{next();render();}toast('本次自评已记入演示，之后独立复习再确认。');},
 'listen-answer'(b){if(!learn.session.readText&&(store.get().quiet||!learn.session.audioPlayed)){toast('请先听完示范；听不到可展开文本，记为阅读补练。');return;}answer(b.dataset.choice==='0'?'correct':'incorrect');},
 'learn-continue'(){commands.complete(words[learn.session.index].id,learn.session.mode==='listen'?(learn.session.readText?'阅读补练':'听辨'):'拼写',learn.session.result);if(learn.session.reviewId){if(learn.session.result==='correct'&&!learn.session.readText)commands.finishReview(learn.session.reviewId,false);learn.session.reviewId=null;route('review');}else{next();render();}toast('本次练习已记入浏览器演示。');},
 'capture-current'(){capture(words[learn.session.index].id);},'capture-focus'(){capture(store.get().focusWord);},
 'save-capture'(){receipt(commands.saveCaptured(),'演示复习点已加入，时间尚未安排。');},
 'cancel-capture'(){store.update(s=>s.capture=null);render();},
 undo(b){receipt(commands.undo(b.dataset.id),'本次收录贡献已撤销；已有练习历史保留。');},
 schedule(b){receipt(commands.schedule(b.dataset.id),'演示已安排：明天 19:30。');},
 'review-pause'(b){commands.pause(b.dataset.id);render();},
 'review-start'(b){const item=store.get().reviews.find(r=>r.id===b.dataset.id);if(!item||item.paused)return;if(item.skill==='发音'){store.update(s=>s.focusWord=item.wordId);route('practice');renderPractice(item);return;}learn.session.index=words.findIndex(w=>w.id===item.wordId);learn.session.mode='recall';learn.session.reviewId=item.id;learn.resetQuestion();route('learn');},
 call(){coach.coach.inCall=!coach.coach.inCall;render();toast(coach.coach.inCall?'模拟通话已开始，不录音。':'模拟通话已结束。');},
 'coach-progress'(){const s=store.get();store.update(s=>s.messages.push({type:'coach',text:`演示中已练 ${s.completed.length} 次；有 ${s.reviews.filter(r=>r.status!=='done'&&!r.paused).length} 项待复习，每日预算 ${s.budget} 分钟。可在计划页调整。`}));render();},
 speak(b){speak(b.dataset.text);},
 'open-word'(b){learn.session.index=words.findIndex(w=>w.id===b.dataset.id);learn.session.mode='recall';learn.session.reviewId=null;learn.resetQuestion();route('learn');},
 'exam-start'(){store.update(s=>s.exam={status:'active',answers:[]});render();},
 'exam-grade'(){store.update(s=>{if(s.exam?.status==='pending')s.exam.status='graded';});render();},
 'exam-publish'(){store.update(s=>{if(s.exam?.status==='graded')s.exam.status='published';});render();},
 'exam-reset'(){store.update(s=>s.exam=null);render();},
 export(){const data=document.querySelector('#data-preview');data.open=true;document.querySelector('#data-json').textContent=JSON.stringify(store.get(),null,2);data.scrollIntoView({block:'nearest'});},
};
// Pronunciation practice is an optional subpage. No objective speech score is produced.
pages.practice={render:()=>practiceItem?`<header class="page-header"><button class="icon-button" data-route="review" aria-label="返回复习">${icon('back')}</button><div><h1>跟读与自听</h1><p>专项练习 · 未自动评测</p></div></header><section class="word-card"><p class="eyebrow">PRONUNCIATION PRACTICE</p><h2 class="word">${getWord(practiceItem.wordId).word}</h2><p class="ipa">${getWord(practiceItem.wordId).ipa}</p><button class="secondary full" data-action="speak" data-text="${getWord(practiceItem.wordId).word}">${icon('audio',20)} 听示范朗读</button><p class="practice-direction">跟读这个词，注意短元音。<br>可以再听一遍，对照自己的发音。</p><span class="skill-tag">SOE 关闭 · 不产生自动分数</span></section><button class="primary full" data-action="finish-practice">我已完成跟读练习</button><p class="small-note">这是自练完成的演示标记，不代表发音达标。<br>不录音，也不保存音频。</p>`:''};
function renderPractice(item){practiceItem=item;location.hash='practice';render({focus:true});}
actions['finish-practice']=()=>{if(store.get().quiet){toast('静音模式下口语练习仍待练，请先关闭静音。');return;}commands.finishReview(practiceItem.id);route('review');toast('演示自练完成；发音未自动评测。');};
document.addEventListener('click',event=>{const button=event.target.closest('button');if(!button||button.disabled)return;if(button.dataset.action){actions[button.dataset.action]?.(button);return;}if(button.dataset.route)route(button.dataset.route);});
document.addEventListener('toggle',event=>{if(event.target.classList.contains('transcript')&&event.target.open){learn.session.readText=true;toast('已转为阅读补练，不记为听辨表现。');}},true);
document.addEventListener('change',event=>{if(event.target.id==='focus-word'){store.update(s=>s.focusWord=event.target.value);render();}if(event.target.form?.id==='exam-form'){const index=Number(event.target.name.slice(1));store.update(s=>{if(s.exam?.status==='active')s.exam.answers[index]=event.target.value;});document.querySelector('.exam-topline span:last-child').textContent=`已答 ${store.get().exam.answers.filter(Boolean).length} / 3`;}});
document.addEventListener('submit',event=>{
 event.preventDefault();const form=event.target;const data=new FormData(form);
 if(form.id==='spell-form'){const value=String(data.get('answer')).trim();if(!value){toast('先试着拼写，再提交。');return;}answer(value.toLowerCase()===words[learn.session.index].word?'correct':'incorrect',value);}
 if(form.id==='plan-form')receipt(commands.plan(data.get('budget'),data.get('mode')),'演示计划已更新，练习历史保留。');
 if(form.id==='coach-form'){const text=String(data.get('message')).trim().slice(0,500);if(!text)return;const target=resolveReviewTarget(text,store.get().focusWord);store.update(s=>s.messages.push({type:'user',text}));if(/复习|发音|明天/.test(text)) {if(target.error){store.update(s=>s.messages.push({type:'coach',text:target.error}));render();return;}commands.capture(target.wordId);render();}else{store.update(s=>s.messages.push({type:'coach',text:'这里先演示加入复习与查看计划。试试输入“ship 明天练发音”，或点击查看进度。'}));render();}}
 if(form.id==='exam-form'){const s=store.get();if(s.exam?.status!=='active')return;if(s.exam.answers.filter(Boolean).length<3){toast('还有未作答的题，请完成后交卷。');return;}store.update(next=>next.exam.status='pending');render();}
 if(form.id==='library-search'||form.id==='material-form'){const text=String(data.get(form.id==='library-search'?'query':'material')).trim().toLowerCase();const results=words.filter(w=>text.includes(w.word)||w.word.includes(text)||w.meaning.includes(text));document.querySelector('#word-results').innerHTML=results.length?results.map(w=>`<button class="word-row" data-action="open-word" data-id="${w.id}"><div><strong>${w.word}</strong><p>${escape(w.meaning)}</p></div>${icon('arrow',18)}</button>`).join(''):'<p class="muted">当前样例词库没有匹配内容。</p>';toast(form.id==='material-form'?'已提取样例匹配词，未导入真实资料。':'搜索完成');}
});
function resetPreview(){store.reset();learn.session.index=0;learn.session.reviewId=null;learn.resetQuestion();coach.coach.inCall=false;practiceItem=null;route('home');render();toast('演示已重置为初始样例。');}
actions['reset-preview']=resetPreview;
document.querySelector('#reset-preview').addEventListener('click',resetPreview);
window.addEventListener('hashchange',()=>{playbackGeneration++;if(active==='coach'&&location.hash!=='#coach')coach.coach.inCall=false;if('speechSynthesis'in window)speechSynthesis.cancel();render({focus:true});});
render();if(store.getError())toast(store.getError());
