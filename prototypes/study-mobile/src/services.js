import {store} from './state.js';
import {getWord} from './content.js';
// Commands own demo state writes. Pages and simulated Agent share this port.
export function createDemoCommands(repository) {
  return {
    complete(wordId,skill,result,context={}) {return repository.update(s=>{s.completed.push({wordId,skill,result,isReview:Boolean(context.isReview),at:Date.now()});});},
    capture(wordId) {return repository.update(s=>{s.capture={wordId,skill:'发音',requestedDay:'明天'};});},
    saveCaptured() {
      const capture=repository.get().capture; if(!capture) return {status:'rejected',error:'请先选择一个词，再模拟语音指令。'};
      const operationId=crypto.randomUUID();
      const receipt=repository.update(s=>{
        let review=s.reviews.find(r=>r.wordId===capture.wordId && r.skill===capture.skill && r.status!=='done');
        if(!review) {review={id:crypto.randomUUID(),...capture,status:'pending',when:null,source:'明确语音指令 · 演示',paused:false};s.reviews.push(review);}
        s.contributions.push({operationId,reviewId:review.id,wordId:capture.wordId}); s.capture=null;
        s.messages.push({type:'receipt',wordId:capture.wordId,operationId,text:`${getWord(capture.wordId).word} 的发音复习点已加入演示，${review.status==='planned'?`已有安排：${review.when}`:'等待安排'}。`});
      }); return {...receipt,operationId,message:repository.get().messages.at(-1)?.text};
    },
    undo(operationId) {return repository.update(s=>{const contribution=s.contributions.find(c=>c.operationId===operationId); if(!contribution) return; s.contributions=s.contributions.filter(c=>c.operationId!==operationId); const hasOthers=s.contributions.some(c=>c.reviewId===contribution.reviewId); s.reviews=s.reviews.filter(r=>r.id!==contribution.reviewId || hasOthers || r.id.startsWith('seed-') || r.status==='done'); s.messages=s.messages.map(m=>m.operationId===operationId?{...m,undone:true}:m);});},
    schedule(id) {return repository.update(s=>{const r=s.reviews.find(r=>r.id===id); if(r){r.status='planned';r.when='明天 19:30';}});},
    pause(id) {return repository.update(s=>{const r=s.reviews.find(r=>r.id===id);if(r)r.paused=!r.paused;});},
    finishReview(id,record=true) {return repository.update(s=>{const r=s.reviews.find(r=>r.id===id);if(r&&r.status!=='done'){r.status='done'; if(record)s.completed.push({wordId:r.wordId,skill:r.skill,result:'self-practice',isReview:true,at:Date.now()});}});},
    plan(budget,mode) {const value=Number(budget);if(![10,20,30,45].includes(value)||!['manual','assisted','managed'].includes(mode))return {status:'rejected',error:'请选择有效的计划设置。'};return repository.update(s=>{s.budget=value;s.mode=mode;});},
  };
}
export const commands=createDemoCommands(store);
