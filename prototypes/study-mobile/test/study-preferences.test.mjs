import test from 'node:test';
import assert from 'node:assert/strict';
import {createStore,initialState} from '../src/state.js';
import {createDemoCommands} from '../src/services.js';
import {createStudyCommands,dailyOverview,eligibleWords,filteredWords,shuffled} from '../src/study-services.js';
import {setRecallDirection} from '../src/learning.js';
import {statisticsQuery} from '../src/statistics.js';
import {render as libraryPage,libraryState,switchDraftBook,selectLetterDraft} from '../src/pages/library.js';
import {render as settingsPage} from '../src/pages/settings.js';
const setup=()=>{
  const memory=new Map();
  const storage={getItem:key=>memory.get(key)??null,setItem:(key,value)=>memory.set(key,value)};
  const state=createStore(storage);
  return {state,storage,commands:createDemoCommands(state),study:createStudyCommands(state)};
};

test('changing books preserves cross-book word history and avoids duplicate selection',()=>{
  const {state,commands,study}=setup();
  commands.complete('journey','词义','self-good');
  study.wordStatus('journey','familiar');
  const selectedBefore=[...state.get().selectedWords];
  study.selectBook('highschool');study.selectBook('cet4');study.selectBook('highschool');
  assert.deepEqual(state.get().selectedWords,selectedBefore);
  assert.equal(state.get().selectedBook,'highschool');
  assert.equal(state.get().wordStatus.journey,'familiar');
  assert.equal(state.get().completed.length,1);
  assert.equal(new Set(state.get().selectedWords).size,state.get().selectedWords.length);
});

test('paused and user-familiar words are excluded from automatic learning but retain history',()=>{
  const {state,commands,study}=setup();
  study.selectBook('highschool');
  commands.complete('ship','拼写','correct');
  study.wordStatus('ship','paused');
  assert.ok(!eligibleWords(state.get()).includes('ship'));
  study.wordStatus('ship','active');
  assert.ok(eligibleWords(state.get()).includes('ship'));
  study.wordStatus('ship','familiar');
  assert.ok(!eligibleWords(state.get()).includes('ship'));
  assert.equal(state.get().completed[0].result,'correct');
});

test('today excludes pending, future and familiar reviews; new words do not duplicate due words',()=>{
  const {state,commands,study}=setup();
  commands.capture('ship');commands.saveCaptured();
  let today=dailyOverview(state.get());
  assert.deepEqual(today.due.map(r=>r.wordId),['journey']);
  assert.ok(!today.newIds.includes('journey'));
  const ship=state.get().reviews.find(r=>r.wordId==='ship');
  commands.schedule(ship.id);
  assert.ok(!dailyOverview(state.get()).due.some(r=>r.wordId==='ship'));
  study.wordStatus('journey','familiar');
  assert.equal(dailyOverview(state.get()).due.length,0);
});

test('daily total respects limit and review-only mode does not invent new tasks',()=>{
  const {state,study}=setup();
  study.selectBook('cet4');
  study.learning({dailyLimit:10,newLimit:30,direction:'cn-en',order:'review'});
  const today=dailyOverview(state.get());
  assert.ok(today.due.length+today.newIds.length<=10);
  study.learning({dailyLimit:20,newLimit:0,direction:'spell',order:'book'});
  assert.equal(dailyOverview(state.get()).newIds.length,0);
});

test('filters overlap deliberately and batch adding repeated words does not erase status',()=>{
  const {state,study}=setup();
  study.selectWords(['evidence','evidence','ship','unknown']);
  study.favorite('evidence');study.wordStatus('evidence','paused');
  assert.equal(state.get().selectedWords.filter(id=>id==='evidence').length,1);
  assert.ok(filteredWords(state.get(),'favorite').some(w=>w.id==='evidence'));
  assert.ok(filteredWords(state.get(),'paused').some(w=>w.id==='evidence'));
  assert.ok(!filteredWords(state.get(),'today').some(w=>w.id==='evidence'));
  assert.equal(filteredWords(state.get(),'all','evidence').length,1);
});

test('V1 records migrate to new preferences without discarding attempts or reviews',()=>{
  const old=initialState();old.schema=1;
  old.completed=[{wordId:'ship',skill:'词义',result:'self-good',at:1}];
  for(const field of ['settings','learning','selectedBook','selectedWords','wordStatus','favorites','notes','goal','modelStates'])delete old[field];
  const restored=createStore({getItem:()=>JSON.stringify(old)}).get();
  assert.equal(restored.schema,2);
  assert.equal(restored.completed.length,1);
  assert.equal(restored.reviews[0].id,'seed-journey');
  assert.equal(restored.settings.asrModel,'balanced');
});

test('preferences persist and a pending model simulation reloads without pretending installation',()=>{
  const {state,storage,study}=setup();
  study.preference('theme','dark');study.preference('asrModel','accurate');
  study.modelState('accurate','loading');
  const restored=createStore(storage).get();
  assert.equal(restored.settings.theme,'dark');
  assert.equal(restored.modelStates.accurate,'pending');
  assert.ok(settingsPage(restored).includes('不下载模型'));
  assert.ok(settingsPage(restored).includes('不是发音评分'));
});

test('actual demo statistics count pronunciation review as review rather than new learning',()=>{
  const {state,commands}=setup();
  commands.capture('ship');commands.saveCaptured();
  const point=state.get().reviews.find(r=>r.wordId==='ship');
  commands.finishReview(point.id);
  const stats=statisticsQuery(state.get(),{tab:'activity',period:'week',source:'actual'});
  assert.equal(stats.series.find(s=>s.id==='review').values.at(-1),1);
  assert.equal(stats.series.find(s=>s.id==='new').values.at(-1),0);
  assert.ok(statisticsQuery(state.get(),{tab:'forget'}).notice.includes('不是个人数据'));
  assert.ok(statisticsQuery(state.get(),{tab:'retention'}).notice.includes('不是你的记忆预测'));
});


test('changing a meaning-recall direction keeps review ownership while changing skills releases it',()=>{
  const attempt={mode:'recall',direction:'en-cn',reviewId:'due-ship'};
  setRecallDirection(attempt,'cn-en');
  assert.equal(attempt.reviewId,'due-ship');
  assert.equal(attempt.direction,'cn-en');
  attempt.mode='spell';setRecallDirection(attempt,'en-cn');
  assert.equal(attempt.reviewId,null);
});

test('letter selection follows current search and book drafts do not leak into another book',()=>{
  const {state}=setup();state.update(s=>{s.selectedWords=[];s.selectedBook='highschool';});
  switchDraftBook('highschool');libraryState.query='ship';
  selectLetterDraft(state.get(),'S');
  assert.deepEqual([...libraryState.draft],['ship']);
  libraryState.query='';libraryState.page=1;
  switchDraftBook('highschool');assert.ok(libraryState.draft.has('ship'));
  assert.equal(switchDraftBook('cet4'),true);
  assert.equal(libraryState.draft.size,0);
  libraryState.page=0;libraryState.query='';
});

test('random order shuffles the new candidate pool before limiting and keeps due reviews first',()=>{
  const {state}=setup();
  state.update(s=>{s.learning.order='random';s.learning.newLimit=5;});
  const bookOrder=dailyOverview(state.get()).newIds;
  const randomized=dailyOverview(state.get(),{random:()=>0}).newIds;
  assert.notDeepEqual(randomized,bookOrder);
  assert.deepEqual(dailyOverview(state.get(),{random:()=>0}).due.map(r=>r.wordId),['journey']);
  const input=['a','b','c'];assert.deepEqual(shuffled(input,()=>0),['b','c','a']);
  assert.deepEqual(input,['a','b','c']);
});
