import {wordIds, getBook, books} from './content.js';
const key = 'shiyu.study-preview.v1';
const validWord=new Set(wordIds);
export function browserStorage() {
  try {return globalThis.localStorage ?? null;} catch {return null;}
}
export const initialState = () => ({
  schema:2,themeRevision:1, budget:20, mode:'assisted', quiet:false,
  completed:[], reviews:[{id:'seed-journey',wordId:'journey',skill:'词义',status:'planned',when:'今天 19:30',source:'昨日拼写练习 · 样例',paused:false}],
  contributions:[], messages:[], focusWord:'ship', capture:null, exam:null,
  selectedBook:'daily', selectedWords: [...new Set(['ship','resilient','journey','transfer',...getBook('daily').ids.slice(0,26)])].filter(id=>validWord.has(id)),
  wordStatus:{habit:'familiar',focus:'paused'}, favorites:[],notes:{},goal:'在日常场景里，自信地说出来。',
  learning:{dailyLimit:50,newLimit:20,direction:'en-cn',order:'book',autoAudio:false},
  settings:{theme:'dark',accent:'sage',asr:'local',asrModel:'balanced',voice:'us',rate:0.85,reminder:true,reminderTime:'19:30',subtitle:true},
  modelStates:{fast:'ready',balanced:'pending',accurate:'failed'},
});
function validBase(saved) {
  return [1,2].includes(saved?.schema) && [10,20,30,45].includes(saved.budget)
    && ['manual','assisted','managed'].includes(saved.mode) && typeof saved.quiet==='boolean'
    && validWord.has(saved.focusWord) && Array.isArray(saved.completed)
    && saved.completed.every(c=>c && validWord.has(c.wordId) && typeof c.skill==='string' && typeof c.result==='string')
    && Array.isArray(saved.contributions) && saved.contributions.every(c=>c && typeof c.operationId==='string' && typeof c.reviewId==='string')
    && Array.isArray(saved.messages) && saved.messages.every(m=>m && typeof m.text==='string' && (!m.operationId || typeof m.operationId==='string'))
    && Array.isArray(saved.reviews) && saved.reviews.every(r=>r && typeof r.id==='string' && validWord.has(r.wordId)
      && ['pending','planned','done'].includes(r.status) && typeof r.skill==='string' && typeof r.source==='string')
    && (saved.capture===null || validWord.has(saved.capture?.wordId))
    && (saved.exam===null || ['active','pending','graded','published'].includes(saved.exam?.status)
      && Array.isArray(saved.exam.answers) && saved.exam.answers.every(a=>a===null || typeof a==='string'));
}
function validPreferences(saved) {
  return books.some(b=>b.id===saved.selectedBook) && Array.isArray(saved.selectedWords) && saved.selectedWords.every(id=>validWord.has(id))
    && saved.wordStatus && Object.entries(saved.wordStatus).every(([id,status])=>validWord.has(id)&&['active','familiar','paused'].includes(status))
    && Array.isArray(saved.favorites) && saved.favorites.every(id=>validWord.has(id))
    && [10,20,30,50,80].includes(saved.learning?.dailyLimit) && [0,5,10,20,30].includes(saved.learning?.newLimit)
    && ['en-cn','cn-en','spell','listen'].includes(saved.learning?.direction) && ['book','random','review'].includes(saved.learning?.order)
    && ['light','dark'].includes(saved.settings?.theme) && ['local','cloud','text'].includes(saved.settings?.asr)
    && ['fast','balanced','accurate'].includes(saved.settings?.asrModel)
    && ['us','uk'].includes(saved.settings?.voice) && [0.7,0.85,1,1.15].includes(saved.settings?.rate)
    && typeof saved.settings?.reminder==='boolean' && /^\d{2}:\d{2}$/.test(saved.settings?.reminderTime ?? '')
    && saved.modelStates && ['fast','balanced','accurate'].every(id=>['ready','pending','failed','loading'].includes(saved.modelStates[id]));
}
export function createStore(storage) {
  let state = initialState();
  let error = null;
  try {
    const saved = JSON.parse(storage?.getItem(key) ?? 'null');
    if(saved?.schema===2 && !books.some(book=>book.id===saved.selectedBook))saved.selectedBook='daily';
    if(saved!==null) {
      if(validBase(saved) && (saved.schema===1 || validPreferences(saved))) {
        // V1 records survive the richer UI; only new preferences receive defaults.
        state = {...state,...saved,schema:2};
        if(saved.themeRevision!==1){state.settings={...state.settings,theme:'dark'};state.themeRevision=1;}
        if(saved.schema===2) state.modelStates=Object.fromEntries(Object.entries(state.modelStates).map(([id,status])=>[id,status==='loading'?'pending':status]));
      } else error='浏览器演示数据格式不兼容，已恢复初始样例。';
    }
  } catch {error='浏览器演示数据无法读取，已使用初始样例。';}
  function persist() {
    try {if(!storage) throw new Error('unavailable'); storage.setItem(key,JSON.stringify(state));error=null;}
    catch {error='浏览器未能保存演示数据，当前操作只保留在本页。';}
    return {status:'preview',persisted:!error,error};
  }
  return {
    get:()=>structuredClone(state),
    update(change) {const next=structuredClone(state);change(next);state=next;return persist();},
    reset() {state=initialState();return persist();},
    getError:()=>error,
  };
}
export const store=createStore(browserStorage());
