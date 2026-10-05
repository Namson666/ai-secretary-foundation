import {getBook, wordIds, words} from './content.js';
export function createStudyCommands(repository) {
  return {
    selectBook(id) {
      const book=getBook(id);
      if(book.id!==id)return {error:'找不到这本词书。'};
      return repository.update(s=>{s.selectedBook=id;});
    },
    selectWords(ids) {return repository.update(s=>{s.selectedWords=[...new Set([...s.selectedWords,...ids.filter(id=>wordIds.includes(id))])];});},
    wordStatus(id,status) {
      if(!wordIds.includes(id)||!['active','familiar','paused'].includes(status))return {error:'无法更新这个词。'};
      return repository.update(s=>{s.wordStatus[id]=status;if(!s.selectedWords.includes(id))s.selectedWords.push(id);});
    },
    favorite(id) {if(!wordIds.includes(id))return {error:'无法收藏这个词。'};return repository.update(s=>{s.favorites=s.favorites.includes(id)?s.favorites.filter(x=>x!==id):[...s.favorites,id];});},
    learning({dailyLimit,newLimit,direction,order}) {
      if(![10,20,30,50,80].includes(Number(dailyLimit))||![0,5,10,20,30].includes(Number(newLimit))||!['en-cn','cn-en','spell','listen'].includes(direction)||!['book','random','review'].includes(order))return {error:'请选择有效的学习设置。'};
      return repository.update(s=>{s.learning={...s.learning,dailyLimit:Number(dailyLimit),newLimit:Number(newLimit),direction,order};});
    },
    note(id,text) {if(!wordIds.includes(id))return {error:'找不到这个词。'};return repository.update(s=>{s.notes??={};s.notes[id]=String(text).slice(0,500);});},
    preference(name,value) {
      const options={theme:['light','dark'],asr:['local','cloud','text'],asrModel:['fast','balanced','accurate'],voice:['us','uk'],rate:[0.7,0.85,1,1.15],reminder:[true,false],subtitle:[true,false]};
      if(!options[name]?.includes(value))return {error:'设置值无效。'};
      return repository.update(s=>s.settings[name]=value);
    },
    modelState(id,status) {if(!['fast','balanced','accurate'].includes(id)||!['ready','pending','failed','loading'].includes(status))return {error:'模型状态无效。'};return repository.update(s=>s.modelStates[id]=status);},
  };
}
export function eligibleWords(state) {
  return getBook(state.selectedBook).ids.filter(id=>state.selectedWords.includes(id)&&!['paused','familiar'].includes(state.wordStatus[id]));
}
export function shuffled(values,random=Math.random) {
  const result=[...values];
  for(let i=result.length-1;i>0;i--){const j=Math.floor(random()*(i+1));[result[i],result[j]]=[result[j],result[i]];}
  return result;
}
export function dailyOverview(state,{random=null}={}) {
  const due=state.reviews.filter(r=>r.status==='planned'&&r.when?.startsWith('今天')&&!r.paused&&!['paused','familiar'].includes(state.wordStatus[r.wordId]));
  const learned=new Set(state.completed.map(a=>a.wordId));
  let candidates=eligibleWords(state).filter(id=>!learned.has(id)&&!due.some(r=>r.wordId===id));
  if(state.learning.order==='random'&&random)candidates=shuffled(candidates,random);
  const newIds=candidates.slice(0,state.learning.newLimit);
  const limit=state.learning.dailyLimit;
  return {due:due.slice(0,limit),newIds:newIds.slice(0,Math.max(0,limit-due.length)),done:state.completed.length,selected:state.selectedWords.length};
}
export function filteredWords(state,filter,query='') {
  const learned=new Set(state.completed.map(a=>a.wordId));
  const today=new Set([...dailyOverview(state).due.map(r=>r.wordId),...dailyOverview(state).newIds]);
  return words.filter(w=>state.selectedWords.includes(w.id)).filter(w=>{
    const status=state.wordStatus[w.id]??'active';
    if(filter==='today')return today.has(w.id);
    if(filter==='reinforce')return learned.has(w.id)&&status==='active';
    if(filter==='familiar')return status==='familiar';
    if(filter==='paused')return status==='paused';
    if(filter==='unplanned')return !today.has(w.id)&&status==='active';
    if(filter==='favorite')return state.favorites.includes(w.id);
    return true;
  }).filter(w=>!query||w.word.includes(query.toLowerCase())||w.meaning.includes(query));
}
