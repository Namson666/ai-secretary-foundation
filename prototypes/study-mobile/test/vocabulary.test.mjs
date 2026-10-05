import test from 'node:test';
import assert from 'node:assert/strict';
import {vocabularyWords,vocabularyBooks,vocabularySources} from '../src/vocabulary-source.js';
import {words,books,getWord,displayType} from '../src/content.js';
import {initialState} from '../src/state.js';
import {render as libraryPage,libraryState} from '../src/pages/library.js';
import {render as learningPage,session} from '../src/pages/learn.js';

test('four real core wordbooks reference canonical offline entries without fake example content',()=>{
  assert.deepEqual(vocabularyBooks.map(b=>b.ids.length),[1000,1500,1500,1500]);
  assert.equal(vocabularyWords.length,2468);
  const canonical=new Set(vocabularyWords.map(w=>w.id));
  assert.equal(canonical.size,vocabularyWords.length);
  for(const book of books){assert.equal(book.coverage,'core-selection');assert.ok(book.ids.every(id=>canonical.has(id)));assert.equal(new Set(book.ids).size,book.ids.length);}
  assert.ok(vocabularyWords.every(w=>w.meaning&&w.sourceId==='ecdict'&&!w.example&&!w.translation&&!w.hint));
  assert.equal(vocabularySources[0].license,'MIT');
  assert.equal(getWord('ship').sourceLabel,'ECDICT 开源词典');
  assert.equal(getWord('ship').exampleSource,'界面示例');
  assert.ok(getWord('abandon').meaning);
  assert.equal(getWord('abandon').example,'');
});

test('large book renders only one bounded page and full-book search finds non-demo words',()=>{
  const state=initialState();state.selectedBook='cet4';
  libraryState.view='book';libraryState.bookTab='all';libraryState.query='';libraryState.page=0;
  assert.equal((libraryPage(state).match(/class="book-select-row"/g)||[]).length,40);
  libraryState.query='abandon';
  const result=libraryPage(state);
  assert.ok(result.includes('<strong>abandon</strong>'));
  assert.equal((result.match(/class="book-select-row"/g)||[]).length,1);
  libraryState.query='';libraryState.view='selected';
});

test('dictionary text is HTML escaped and missing hint/example stays explicitly absent',()=>{
  session.index=words.findIndex(w=>w.id==='abandon');session.direction='en-cn';session.mode='recall';session.revealed=false;session.hinted=false;
  const original=getWord('abandon').meaning;
  getWord('abandon').meaning='<img src=x onerror=alert(1)>';
  session.revealed=true;session.wordTab='usage';
  const view=learningPage(initialState());
  assert.ok(view.includes('&lt;img'));
  assert.ok(!view.includes('<img src=x'));
  assert.ok(view.includes('暂无例句'));
  getWord('abandon').meaning=original;session.wordTab='meaning';
  assert.ok(learningPage(initialState()).includes(original.split('\n')[0]));
  session.revealed=false;
  assert.match(learningPage(initialState()),/data-action="learn-hint" disabled>暂无额外提示/);
  session.index=0;
});


test('presentation does not duplicate dictionary part-of-speech labels',()=>{
  assert.equal(displayType({meaning:'n. 船',type:'n.'}),'');
  assert.equal(displayType({meaning:'vt. 放弃',type:'vt.'}),'');
  assert.equal(displayType({meaning:'船；舰',type:'n.'}),'n.');
});
