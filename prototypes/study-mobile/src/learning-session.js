// UI-only recovery; these fields never become domain learning evidence by themselves.
import {wordIds} from './content.js';
const key='shiyu.learning-session.v1';
const validWords=new Set(wordIds);
export function sessionStoragePort(){try{return globalThis.sessionStorage??null;}catch{return null;}}
export function saveLearningSession(storage,session,wordId){
  try{storage?.setItem(key,JSON.stringify({queue:session.queue,wordId,mode:session.mode,direction:session.direction,reviewId:session.reviewId??null,revealed:session.revealed,hinted:session.hinted,result:session.result,answer:session.answer,readText:session.readText,focus:session.focus,wordTab:session.wordTab}));}catch{/* Memory remains usable when browser recovery storage is unavailable. */}
}
export function restoreLearningSession(storage,state){
  try{
    const saved=JSON.parse(storage?.getItem(key)??'null');
    const selected=new Set(state.selectedWords);
    if(!saved||!Array.isArray(saved.queue)||!saved.queue.length||saved.queue.length>state.learning.dailyLimit
      ||new Set(saved.queue).size!==saved.queue.length||!saved.queue.includes(saved.wordId)
      ||!saved.queue.every(id=>validWords.has(id)&&selected.has(id)&&!['paused','familiar'].includes(state.wordStatus[id]))
      ||!['recall','spell','listen'].includes(saved.mode)||!['en-cn','cn-en','spell','listen'].includes(saved.direction)
      ||!['meaning','usage','notes'].includes(saved.wordTab)||typeof saved.revealed!=='boolean'||typeof saved.hinted!=='boolean'
      ||typeof saved.readText!=='boolean'||typeof saved.answer!=='string'||![null,'self-recalled','correct','incorrect'].includes(saved.result))return null;
    const review=state.reviews.find(r=>r.id===saved.reviewId&&r.wordId===saved.wordId&&r.status!=='done'&&!r.paused);
    return {...saved,reviewId:review?.id??null,audioPlayed:false};
  }catch{return null;}
}
export function clearLearningSession(storage){try{storage?.removeItem(key);}catch{/* Recovery remains optional. */}}
