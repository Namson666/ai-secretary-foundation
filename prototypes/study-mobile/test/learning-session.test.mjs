import test from 'node:test';
import assert from 'node:assert/strict';
import {initialState} from '../src/state.js';
import {saveLearningSession,restoreLearningSession,clearLearningSession} from '../src/learning-session.js';
const storage=()=>{const values=new Map();return {getItem:k=>values.get(k)??null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};};
const attempt={queue:['ship','journey'],mode:'recall',direction:'cn-en',reviewId:null,revealed:true,hinted:true,result:null,answer:'',readText:true,focus:true,wordTab:'meaning',audioPlayed:true};
test('reload recovers exact selected word, queue and hint evidence without reusing audio authorization',()=>{
  const memory=storage();saveLearningSession(memory,attempt,'ship');
  const saved=restoreLearningSession(memory,initialState());
  assert.equal(saved.wordId,'ship');assert.deepEqual(saved.queue,['ship','journey']);
  assert.equal(saved.direction,'cn-en');assert.equal(saved.revealed,true);assert.equal(saved.hinted,true);assert.equal(saved.audioPlayed,false);assert.equal(saved.readText,true);
});
test('absent, unselected or retired learning queue cannot default to unrestricted vocabulary',()=>{
  const memory=storage();assert.equal(restoreLearningSession(memory,initialState()),null);
  const state=initialState();saveLearningSession(memory,attempt,'ship');state.selectedWords=state.selectedWords.filter(id=>id!=='ship');
  assert.equal(restoreLearningSession(memory,state),null);
  state.selectedWords.push('ship');state.wordStatus.ship='paused';assert.equal(restoreLearningSession(memory,state),null);
  clearLearningSession(memory);assert.equal(restoreLearningSession(memory,initialState()),null);
});
