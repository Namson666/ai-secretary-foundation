import {store} from './state.js';
import {commands} from './services.js';
import {createStudyCommands,dailyOverview} from './study-services.js';
import {words,getWord,getBook} from './content.js';
import {sessionStoragePort,saveLearningSession,restoreLearningSession,clearLearningSession} from './learning-session.js';
import {canRateIndependent,setRecallDirection} from './learning.js';
import {resolveReviewTarget} from './agent-intent.js';
import {icon,toast,header,escape} from './ui.js';
import * as home from './pages/home.js';
import * as learn from './pages/learn.js';
import * as review from './pages/review.js';
import * as plan from './pages/plan.js';
import * as coach from './pages/coach.js';
import * as library from './pages/library.js';
import * as profile from './pages/profile.js';
import * as exam from './pages/exam.js';
import * as stats from './pages/stats.js';
import * as settings from './pages/settings.js';
import * as learningSettings from './pages/learning-settings.js';

const study=createStudyCommands(store);
const learningStorage=sessionStoragePort();
const pages={home,learn,review,plan,coach,library,profile,exam,stats,settings,'learning-settings':learningSettings};
const navigation=[
  {id:'home',label:'今日',icon:'home',routes:['home','review','learn','practice','plan']},
  {id:'library',label:'选词',icon:'book',routes:['library','learning-settings']},
  {id:'stats',label:'统计',icon:'chart',routes:['stats']},
  {id:'coach',label:'AI',icon:'coach',routes:['coach']},
  {id:'profile',label:'我的',icon:'user',routes:['profile','settings','exam']},
];
const app=document.querySelector('#app');
const device=document.querySelector('.device');
let active='home';
let playbackGeneration=0;
let practiceItem=null;
let pageCleanup=null;
const modelTimers=new Set();

function render({focus=false}={}) {
  const requested=location.hash.slice(1);
  let nextPage=pages[requested]?requested:'home';
  if(nextPage==='learn'&&!learn.session.queue.length){
    const recovered=restoreLearningSession(learningStorage,store.get());
    if(recovered){Object.assign(learn.session,recovered,{index:words.findIndex(w=>w.id===recovered.wordId)});}
    else{nextPage='home';history.replaceState(null,'','#home');}
  }
  if(nextPage==='practice'&&!practiceItem)nextPage='review';
  pageCleanup?.();pageCleanup=null;
  if(active==='coach'&&nextPage!=='coach')coach.leave?.();
  active=nextPage;
  const state=store.get();
  document.documentElement.dataset.theme=state.settings.theme;
  device.classList.toggle('word-selection-mode',active==='library'&&library.libraryState.view==='book');
  device.classList.toggle('learning-focused',active==='learn'&&learn.session.focus);
  device.classList.toggle('coach-call-active',active==='coach'&&Boolean(coach.coach?.inCall&&coach.coach?.expanded));
  app.dataset.page=active;
  if(active==='learn')saveLearningSession(learningStorage,learn.session,words[learn.session.index].id);
  app.innerHTML=pages[active].render(state);
  document.querySelector('#navigation').innerHTML=navigation.map(item=>`<button data-route="${item.id}" ${item.routes.includes(active)?'aria-current="page"':''}>${icon(item.icon)}<span>${item.label}</span></button>`).join('');
  if(focus){app.scrollTop=0;app.focus({preventScroll:true});}
  pageCleanup=pages[active].mount?.(app,{store,commands,route,toast,speak,render,capture})??null;
}
function prepareLearning(wordId=null,reviewId=null) {
  const state=store.get();
  if(wordId&&!state.selectedWords.includes(wordId)){toast('请先勾选并确认加入这个词，再开始练习。');return false;}
  const today=dailyOverview(state,{random:Math.random});
  let queue=[...new Set([...today.due.map(r=>r.wordId),...today.newIds])];
  if(!queue.length&&!wordId){toast('当前没有可执行的今日任务。只复习模式可先安排复习点，或调整新词上限。');return false;}
  if(wordId)queue=[wordId,...queue.filter(id=>id!==wordId)];
  if(!queue.length){toast('当前没有可学习的词，请恢复暂停词或选择新词书。');return false;}
  if(state.learning.order==='review')queue.sort((a,b)=>Number(state.completed.some(c=>c.wordId===b))-Number(state.completed.some(c=>c.wordId===a)));
  if(wordId)queue=[wordId,...queue.filter(id=>id!==wordId)];
  learn.session.queue=queue.slice(0,state.learning.dailyLimit);
  learn.session.index=words.findIndex(w=>w.id===queue[0]);
  learn.session.reviewId=reviewId??today.due.find(r=>r.wordId===queue[0]&&r.skill==='词义')?.id??null;
  learn.session.direction=state.learning.direction;
  learn.session.mode=['spell','listen'].includes(state.learning.direction)?state.learning.direction:'recall';
  if(learn.session.reviewId){const task=state.reviews.find(r=>r.id===learn.session.reviewId);learn.session.mode=task?.skill==='拼写'?'spell':task?.skill==='听辨'?'listen':'recall';if(learn.session.mode==='recall'&&!['en-cn','cn-en'].includes(learn.session.direction))learn.session.direction='en-cn';}
  learn.resetQuestion();
  return true;
}
function route(name,{prepared=false}={}) {
  if(!name||!pages[name])return;
  if(name==='learn'&&active!=='learn'&&!prepared&&!prepareLearning())return;
  if(active===name)render({focus:true});else location.hash=name;
}
function receipt(result,success) {toast(result.error??result.message??success);render();}
function next() {
  learn.session.reviewId=null;
  const state=store.get();
  const remaining=learn.session.queue.filter(id=>!['paused','familiar'].includes(state.wordStatus[id]));
  const current=words[learn.session.index].id;
  const position=remaining.indexOf(current);
  const nextId=remaining[(position+1)%remaining.length];
  if(!nextId){route('home');toast('这组内容已无可学习词，去选词页继续添加。');return;}
  learn.session.queue=remaining;
  learn.session.index=words.findIndex(w=>w.id===nextId);
  learn.session.reviewId=dailyOverview(state).due.find(r=>r.wordId===nextId&&r.skill==='词义')?.id??null;
  learn.session.direction=state.learning.direction;learn.session.mode=['spell','listen'].includes(state.learning.direction)?state.learning.direction:'recall';
  if(learn.session.reviewId){learn.session.mode='recall';if(!['en-cn','cn-en'].includes(learn.session.direction))learn.session.direction='en-cn';}
  learn.resetQuestion();
}
function capture(wordId) {
  commands.capture(wordId);
  store.update(s=>s.messages.push({type:'user',text:`“这个词明天练发音。”（模拟语音，指向 ${getWord(wordId).word}）`}));
  route('coach');render();
}
function answer(result,answerText='') {
  learn.session.result=result;learn.session.answer=answerText;learn.session.revealed=true;render();
}
function speak(text) {
  const state=store.get();
  if(active==='learn'&&learn.session.mode==='recall'&&learn.session.direction==='cn-en'&&!learn.session.revealed&&text===words[learn.session.index].word){learn.session.hinted=true;render();}
  if(state.quiet){toast('静音模式已开启。可以阅读文本；口语任务仍待练。');return;}
  if(!('speechSynthesis'in window)){toast('本浏览器无法朗读，请阅读文本继续。');return;}
  const playback=++playbackGeneration,generation=learn.session.generation,mode=learn.session.mode;
  const word=words[learn.session.index];
  speechSynthesis.cancel();
  const utterance=new SpeechSynthesisUtterance(text);
  utterance.lang=state.settings.voice==='uk'?'en-GB':'en-US';utterance.rate=state.settings.rate;
  utterance.onend=()=>{
    if(playback===playbackGeneration&&generation===learn.session.generation&&mode==='listen'&&text===(word.example||word.word)
      &&active==='learn'&&learn.session.mode==='listen'&&words[learn.session.index].id===word.id&&!learn.session.revealed){
      learn.session.audioPlayed=true;toast('示范播放结束，现在可以选择。');
    }
  };
  utterance.onerror=()=>{if(playback===playbackGeneration)toast('朗读未能播放，请阅读文本继续。');};
  speechSynthesis.speak(utterance);toast('正在使用浏览器示范朗读');
}
function autoSelectWords(random) {
  const state=store.get();let ids=getBook(state.selectedBook).ids.filter(id=>!state.selectedWords.includes(id)&&!library.libraryState.draft.has(id));
  if(state.learning.newLimit===0){toast('新词上限为 0，请先调整学习量或手动勾选。');return;}
  if(random){for(let i=ids.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[ids[i],ids[j]]=[ids[j],ids[i]];}}
  ids.slice(0,state.learning.newLimit).forEach(id=>library.libraryState.draft.add(id));render();toast('已加入勾选草案，点击确认后才保存。');
}
function openWord(id,reviewId=null) {if(!prepareLearning(id,reviewId))return;route('learn',{prepared:true});}
function persistAttempt(skill,result) {
  return commands.complete(words[learn.session.index].id,skill,result,{isReview:Boolean(learn.session.reviewId)});
}
const actions={
  quiet(){store.update(s=>s.quiet=!s.quiet);if(store.get().quiet){playbackGeneration++;if('speechSynthesis'in window)speechSynthesis.cancel();}render();},
  'learn-mode'(button){learn.session.reviewId=null;learn.session.mode=button.dataset.mode;learn.resetQuestion();render();},
  'learn-direction'(b){setRecallDirection(learn.session,b.dataset.direction);learn.resetQuestion();render();},
  'learn-focus'(){learn.session.focus=!learn.session.focus;render();},
  'learn-familiar'(){study.wordStatus(words[learn.session.index].id,'familiar');next();render();toast('已标熟知，属于用户设置；旧练习记录保留。');},
  'recall-claimed'(){if(learn.session.hinted)return;learn.session.result='self-recalled';learn.session.revealed=true;render();},
  'learn-next'(){next();render();},
  'learn-hint'(){if(!words[learn.session.index].hint){toast('这条词库词条没有额外提示。');return;}learn.session.hinted=true;render();},
  'learn-reveal'(){learn.session.hinted=true;learn.session.revealed=true;render();},
  'learn-rate'(button){
    const rating=button.dataset.rating;
    if(!['again','forgot'].includes(rating)&&!canRateIndependent(learn.session))return;
    persistAttempt('词义',learn.session.hinted?(rating==='forgot'?'assisted-forgot':'assisted'):(rating==='forgot'?'self-again':`self-${rating}`));
    if(learn.session.reviewId){
      if(!['again','forgot'].includes(rating)&&!learn.session.hinted)commands.finishReview(learn.session.reviewId,false);
      learn.session.reviewId=null;route('review');
    }else next();
    render();toast('已记录这次演示尝试；继续独立复习再确认。');
  },
  'listen-answer'(button){
    if(!learn.session.readText&&(store.get().quiet||!learn.session.audioPlayed)){toast('请先听完示范；听不到可展开文本，记为阅读补练。');return;}
    answer(button.dataset.choice==='0'?'correct':'incorrect');
  },
  'learn-continue'(){
    persistAttempt(learn.session.mode==='listen'?(learn.session.readText?'阅读补练':'听辨'):'拼写',learn.session.result);
    if(learn.session.reviewId){
      if(learn.session.result==='correct'&&!learn.session.readText)commands.finishReview(learn.session.reviewId,false);
      learn.session.reviewId=null;route('review');
    }else next();
    render();toast('本次尝试已记录到浏览器演示。');
  },
  'word-detail-tab'(button){learn.session.wordTab=button.dataset.tab;render();},
  'capture-current'(){capture(words[learn.session.index].id);},
  'capture-word'(button){capture(button.dataset.id);},
  'capture-focus'(){capture(store.get().focusWord);},
  'save-capture'(){receipt(commands.saveCaptured(),'演示复习点已加入。');},
  'cancel-capture'(){store.update(s=>s.capture=null);render();},
  undo(button){receipt(commands.undo(button.dataset.id),'本次收录贡献已撤销；已有练习历史保留。');},
  schedule(button){receipt(commands.schedule(button.dataset.id),'演示已安排：明天 19:30。');},
  'review-pause'(button){commands.pause(button.dataset.id);render();},
  'review-filter'(button){review.reviewState.filter=button.dataset.filter;render();},
  'review-start'(button){
    const item=store.get().reviews.find(r=>r.id===button.dataset.id);
    if(!item||item.paused)return;
    if(item.skill==='发音'){store.update(s=>s.focusWord=item.wordId);practiceItem=item;route('practice');return;}
    openWord(item.wordId,item.id);
  },
  'coach-progress'(){
    const s=store.get();
    store.update(next=>next.messages.push({type:'coach',text:`演示中已练 ${s.completed.length} 次；有 ${s.reviews.filter(r=>r.status!=='done'&&!r.paused).length} 项复习点，每日预算 ${s.budget} 分钟。可在计划页调整。`}));render();
  },
  speak(button){speak(button.dataset.text);},
  'open-word'(button){openWord(button.dataset.id);},
  'catalog-open'(){library.libraryState.view='catalog';render();},
  'catalog-close'(){library.libraryState.view='selected';library.libraryState.page=0;library.libraryState.query='';render();},
  'open-current-book'(){library.switchDraftBook(store.get().selectedBook);library.libraryState.view='book';library.libraryState.page=0;library.libraryState.query='';render();},
  'book-tab'(b){library.libraryState.bookTab=b.dataset.tab;library.libraryState.page=0;render();},
  'book-letter'(b){library.libraryState.letter=b.dataset.letter;library.libraryState.page=0;render();},
  'book-toggle-word'(b){const draft=library.libraryState.draft;if(draft.has(b.dataset.id))draft.delete(b.dataset.id);else draft.add(b.dataset.id);render();},
  'library-page'(b){library.libraryState.page=Math.max(0,library.libraryState.page+Number(b.dataset.step));render({focus:true});},
  'sequential-select'(){autoSelectWords(false);},
  'random-select'(){autoSelectWords(true);},
  'select-letter'(b){library.selectLetterDraft(store.get(),b.dataset.letter);render();},
  'clear-draft'(){library.libraryState.draft.clear();render();},
  'confirm-words'(){receipt(study.selectWords([...library.libraryState.draft]),'所勾选词已加入学习范围，原有记录保留。');library.libraryState.draft.clear();render();},
  'book-source'(){library.libraryState.sourceOpen=!library.libraryState.sourceOpen;render();},
  'book-category'(button){library.libraryState.category=button.dataset.category;render();},
  'select-book'(button){const discarded=library.switchDraftBook(button.dataset.id);library.libraryState.view='book';library.libraryState.filter='all';library.libraryState.query='';library.libraryState.page=0;library.libraryState.bookTab='unselected';receipt(study.selectBook(button.dataset.id),discarded?'已切换词书，上一词书未确认勾选已清空；已保存记录保留。':'已打开词书。勾选并确认后才加入已选词。');},
  'word-filter'(button){library.libraryState.filter=button.dataset.filter;library.libraryState.page=0;render();},
  'word-menu'(button){library.libraryState.selectedWord=library.libraryState.selectedWord===button.dataset.id?null:button.dataset.id;render();},
  'word-familiar'(button){receipt(study.wordStatus(button.dataset.id,'familiar'),'已标熟知，不代表客观掌握。');},
  'word-pause'(button){const current=store.get().wordStatus[button.dataset.id];receipt(study.wordStatus(button.dataset.id,current==='paused'?'active':'paused'),current==='paused'?'已恢复日常学习。':'已暂停，历史仍保留。');},
  'word-active'(button){receipt(study.wordStatus(button.dataset.id,'active'),'已加入学习范围，按当日上限排入样例队列。');},
  'word-favorite'(button){receipt(study.favorite(button.dataset.id),'收藏状态已更新。');},
  'stats-tab'(button){stats.statsState.tab=button.dataset.tab;stats.statsState.selected=3;render();},
  'stats-period'(button){stats.statsState.period=button.dataset.period;stats.statsState.selected=0;render();},
  'stats-point'(button){stats.statsState.selected=Number(button.dataset.index);render();},
  'stats-series'(button){const id=button.dataset.series;stats.statsState.visible[id]=!stats.statsState.visible[id];render();},
  'week-day'(button){stats.statsState.tab='activity';stats.statsState.period='week';stats.statsState.selected=Number(button.dataset.day);route('stats');},
  'plan-tab'(button){plan.planState.tab=button.dataset.tab;render();},
  'plan-day'(button){plan.planState.day=Number(button.dataset.day);render();},
  'pause-management'(){receipt(commands.plan(store.get().budget,'manual'),'托管已暂停，历史与已安排任务保留。');},
  'asr-model'(button){receipt(study.preference('asrModel',button.dataset.id),'演示识别模型选择已更新，未加载真实模型。');},
  'simulate-model'(button){
    study.modelState(button.dataset.id,'loading');render();toast('模拟准备模型，不执行下载。');
    const timer=setTimeout(()=>{modelTimers.delete(timer);study.modelState(button.dataset.id,'ready');if(active==='settings')render();toast('模拟状态已就绪，不代表真实安装。');},1100);
    modelTimers.add(timer);
  },
  'theme-toggle'(){study.preference('theme',store.get().settings.theme==='dark'?'light':'dark');render();},
  'reminder-toggle'(){receipt(study.preference('reminder',!store.get().settings.reminder),'提醒界面偏好已保存，未建立系统通知。');},
  'exam-start'(){store.update(s=>s.exam={status:'active',answers:[]});render();},
  'exam-grade'(){store.update(s=>{if(s.exam?.status==='pending')s.exam.status='graded';});render();},
  'exam-publish'(){store.update(s=>{if(s.exam?.status==='graded')s.exam.status='published';});render();},
  'exam-reset'(){store.update(s=>s.exam=null);render();},
  export(){const data=document.querySelector('#data-preview');data.open=true;document.querySelector('#data-json').textContent=JSON.stringify(store.get(),null,2);data.scrollIntoView({block:'nearest'});},
};
pages.practice={render:()=>practiceItem?`${header('跟读与自听','专项练习 · 未自动评测','review')}<section class="word-card"><p class="eyebrow">PRONUNCIATION PRACTICE</p><h2 class="word">${escape(getWord(practiceItem.wordId).word)}</h2><p class="ipa">${escape(getWord(practiceItem.wordId).ipa)}</p><button class="secondary full" data-action="speak" data-text="${escape(getWord(practiceItem.wordId).word)}">${icon('audio',20)} 听示范朗读</button><p class="practice-direction">跟读这个词，听一听自己的发音。<br>可以再听示范，对照尝试。</p><span class="skill-tag">SOE 关闭 · 不产生自动分数</span></section><button class="primary full" data-action="finish-practice">我已完成跟读练习</button><p class="small-note">自练完成不代表发音达标；不录音、不保存音频。</p>`:''};
actions['finish-practice']=()=>{if(store.get().quiet){toast('静音模式下口语练习仍待练，请先关闭静音。');return;}commands.finishReview(practiceItem.id);route('review');toast('演示自练完成；发音未自动评测。');};

function change(event) {
  const target=event.target;
  if(target.id==='focus-word'){store.update(s=>s.focusWord=target.value);render();}
  if(target.id==='stats-source'){stats.statsState.source=target.value;render();}
  if(target.name==='asr-engine')receipt(study.preference('asr',target.value),'识别入口偏好已更新，不调用真实服务。');
  if(target.id==='voice-accent')receipt(study.preference('voice',target.value),'浏览器示范口音已更新。');
  if(target.id==='speech-rate')receipt(study.preference('rate',Number(target.value)),'朗读速度已更新。');
  if(target.form?.id==='exam-form'){
    const index=Number(target.name.slice(1));
    store.update(s=>{if(s.exam?.status==='active')s.exam.answers[index]=target.value;});
    document.querySelector('.exam-topline span:last-child').textContent=`已答 ${store.get().exam.answers.filter(Boolean).length} / 3`;
  }
}
function submit(event) {
  event.preventDefault();const form=event.target,data=new FormData(form);
  if(form.id==='spell-form'){
    const value=String(data.get('answer')).trim();if(!value){toast('先试着拼写，再提交。');return;}
    answer(value.toLowerCase()===words[learn.session.index].word?'correct':'incorrect',value);
  }
  if(form.id==='word-note-form')receipt(study.note(words[learn.session.index].id,data.get('note')),'本词演示笔记已保存。');
  if(form.id==='learning-settings-form')receipt(study.learning(Object.fromEntries(data)),'学习偏好已保存，下一组任务按新设置开始。');
  if(form.id==='plan-form'){
    const result=commands.plan(data.get('budget'),data.get('mode'));
    if(!result.error)store.update(s=>s.goal=String(data.get('goal')).trim().slice(0,100)||'在日常场景里，自信地说出来。');
    receipt(result,'目标与预算已更新，练习历史保留。');
  }
  if(form.id==='coach-form'){
    const text=String(data.get('message')).trim().slice(0,500);if(!text)return;
    const target=resolveReviewTarget(text,store.get().focusWord);
    store.update(s=>s.messages.push({type:'user',text}));
    if(/复习|发音|明天/.test(text)){
      if(target.error){store.update(s=>s.messages.push({type:'coach',text:target.error}));render();return;}
      commands.capture(target.wordId);render();
    }else{store.update(s=>s.messages.push({type:'coach',text:'可以和我聊学习计划，也可以输入“ship 明天练发音”试着加入复习。这里是预设回复演示，没有调用模型。'}));render();}
  }
  if(form.id==='exam-form'){
    const state=store.get();if(state.exam?.status!=='active')return;
    if(state.exam.answers.filter(Boolean).length<3){toast('还有未作答的题，请完成后交卷。');return;}
    store.update(s=>s.exam.status='pending');render();
  }
  if(form.id==='library-search'||form.id==='book-search'){library.libraryState.query=String(data.get('query')).trim().toLowerCase();library.libraryState.page=0;render();toast('搜索完成');}
  if(form.id==='material-form'){
    const text=String(data.get('material')).trim().toLowerCase();
    const tokens=new Set(text.match(/[a-z]+(?:['-][a-z]+)*/g)??[]);
    const ids=words.filter(w=>tokens.has(w.word.toLowerCase())).map(w=>w.id);
    if(!ids.length){toast('这段文字没有匹配的词库词条，不作导入。');return;}
    study.selectWords(ids);library.libraryState.query='';library.libraryState.filter='all';render();toast(`已加入 ${ids.length} 个匹配词，不上传资料。`);
  }
}
function resetPreview() {
  for(const timer of modelTimers)clearTimeout(timer);modelTimers.clear();
  clearLearningSession(learningStorage);store.reset();learn.session.index=0;learn.session.reviewId=null;learn.session.queue=[];learn.session.focus=false;learn.resetQuestion();
  library.libraryState.filter='all';library.libraryState.query='';library.libraryState.view='selected';library.libraryState.selectedWord=null;library.libraryState.page=0;library.libraryState.draft.clear();library.libraryState.draftBook=null;
  plan.planState.tab='schedule';plan.planState.day=0;review.reviewState.filter='all';
  coach.leave?.();practiceItem=null;route('home');render();toast('全部演示数据与队列已重置。');
}
actions['reset-preview']=resetPreview;
document.addEventListener('click',event=>{
  const button=event.target.closest('button');if(!button||button.disabled)return;
  if(button.dataset.action){
    if(actions[button.dataset.action])actions[button.dataset.action](button);
    else if(active==='coach')coach.handleAction?.(button.dataset.action,button,{store,commands,route,toast,speak,render,capture});
    return;
  }
  if(button.dataset.route)route(button.dataset.route);
});
document.addEventListener('toggle',event=>{
  if(active==='learn'&&event.target.classList.contains('transcript')&&event.target.open){learn.session.readText=true;saveLearningSession(learningStorage,learn.session,words[learn.session.index].id);toast('已转为阅读补练，不记为听辨表现。');}
},true);
document.addEventListener('change',change);
document.addEventListener('submit',submit);
document.querySelector('#reset-preview').addEventListener('click',resetPreview);
window.addEventListener('hashchange',()=>{playbackGeneration++;if('speechSynthesis'in window)speechSynthesis.cancel();render({focus:true});});
render();if(store.getError())toast(store.getError());
