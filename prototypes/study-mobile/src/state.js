const key = 'shiyu.study-preview.v1';
export function browserStorage() {try {return globalThis.localStorage ?? null;} catch {return null;}}
function valid(saved) {return saved?.schema===1 && [10,20,30,45].includes(saved.budget) && ['manual','assisted','managed'].includes(saved.mode) && typeof saved.quiet==='boolean' && ['ship','resilient','journey'].includes(saved.focusWord) && Array.isArray(saved.completed) && Array.isArray(saved.contributions) && saved.contributions.every(c=>c && typeof c.operationId==='string' && typeof c.reviewId==='string') && Array.isArray(saved.messages) && saved.messages.every(m=>m && typeof m.text==='string' && (!m.operationId || typeof m.operationId==='string')) && Array.isArray(saved.reviews) && saved.reviews.every(r=>r && typeof r.id==='string' && ['ship','resilient','journey'].includes(r.wordId) && ['pending','planned','done'].includes(r.status) && typeof r.skill==='string' && typeof r.source==='string') && (saved.capture===null || ['ship','resilient','journey'].includes(saved.capture?.wordId)) && (saved.exam===null || ['active','pending','graded','published'].includes(saved.exam?.status) && Array.isArray(saved.exam.answers) && saved.exam.answers.every(a=>a===null || typeof a==='string'));}
export const initialState = () => ({schema:1,budget:20,mode:'assisted',quiet:false,completed:[],reviews:[{id:'seed-journey',wordId:'journey',skill:'词义',status:'planned',when:'今天 19:30',source:'昨日拼写练习 · 样例',paused:false}],contributions:[],messages:[],focusWord:'ship',capture:null,exam:null});
export function createStore(storage) {
  let state = initialState(); let error = null;
  try {const saved = JSON.parse(storage?.getItem(key) ?? 'null'); if(saved!==null) {if(valid(saved)) state={...state,...saved}; else error='浏览器演示数据格式不兼容，已恢复初始样例。';}} catch {error = '浏览器演示数据无法读取，已使用初始样例。';}
  return {
    get: () => structuredClone(state),
    update(change) {const next = structuredClone(state); change(next); state=next; try {if(!storage) throw new Error('unavailable'); storage.setItem(key,JSON.stringify(state)); error=null;} catch {error='浏览器未能保存演示数据，当前操作只保留在本页。';} return {status:'preview',persisted:!error,error};},
    reset() {state=initialState(); try {if(!storage) throw new Error('unavailable'); storage.setItem(key,JSON.stringify(state)); error=null;} catch {error='重置后的演示数据只保留在本页。';}},
    getError:()=>error,
  };
}
export const store = createStore(browserStorage());
