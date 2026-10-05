import {words,books,getBook,getWord,sources,displayType} from '../content.js';
import {header,icon,go,escape,section} from '../ui.js';
import {filteredWords} from '../study-services.js';
export const libraryState={view:'selected',filter:'all',query:'',category:'全部',selectedWord:null,page:0,bookTab:'unselected',draft:new Set(),draftBook:null,sourceOpen:false,letter:'A'};
export function switchDraftBook(bookId) {
  const discarded=Boolean(libraryState.draftBook&&libraryState.draftBook!==bookId&&libraryState.draft.size);
  if(libraryState.draftBook!==bookId)libraryState.draft.clear();
  libraryState.draftBook=bookId;
  return discarded;
}
export function matchingBookWords(state) {
  const query=libraryState.query.toLowerCase();
  return getBook(state.selectedBook).ids.map(getWord).filter(w=>!query||w.word.toLowerCase().includes(query)||w.meaning.includes(query));
}
export function selectLetterDraft(state,letter) {
  for(const word of matchingBookWords(state))if(word.word[0].toUpperCase()===letter&&!state.selectedWords.includes(word.id))libraryState.draft.add(word.id);
}
const PAGE_SIZE=40;
const filters=[['all','全部'],['today','今日'],['reinforce','巩固'],['familiar','熟知'],['paused','暂停'],['unplanned','未安排'],['favorite','收藏']];
function wordList(list,state) {
  return list.map(w=>`<article class="word-entry"><button class="word-entry-main" data-action="open-word" data-id="${escape(w.id)}"><strong>${escape(w.word)} ${state.favorites.includes(w.id)?'<span class="favorite-star">★</span>':''}</strong><span>${w.ipa?escape(w.ipa):'音标待补充'}</span><p>${escape(displayType(w))} ${escape(w.meaning)}</p></button><div class="word-entry-controls"><span class="word-state ${state.wordStatus[w.id]??'active'}">${state.wordStatus[w.id]==='familiar'?'已标熟知':state.wordStatus[w.id]==='paused'?'已暂停':state.completed.some(a=>a.wordId===w.id)?'有记录':'未练习'}</span><button class="icon-button" data-action="word-menu" data-id="${escape(w.id)}" aria-label="管理 ${escape(w.word)}">${icon('more',20)}</button></div>${libraryState.selectedWord===w.id?`<div class="word-action-sheet"><button data-action="word-familiar" data-id="${escape(w.id)}">标记熟知</button><button data-action="word-pause" data-id="${escape(w.id)}">${state.wordStatus[w.id]==='paused'?'恢复学习':'暂停学习'}</button><button data-action="word-active" data-id="${escape(w.id)}">加入学习范围</button><button data-action="word-favorite" data-id="${escape(w.id)}">${state.favorites.includes(w.id)?'取消收藏':'收藏'}</button><button data-action="capture-word" data-id="${escape(w.id)}">加入发音复习</button></div>`:''}</article>`).join('');
}
function pagination(length) {
  const pages=Math.max(1,Math.ceil(length/PAGE_SIZE));
  libraryState.page=Math.min(libraryState.page,pages-1);
  return length>PAGE_SIZE?`<div class="pagination"><button data-action="library-page" data-step="-1" ${libraryState.page===0?'disabled':''}>${icon('back',17)} 上一页</button><span>${libraryState.page+1} / ${pages}</span><button data-action="library-page" data-step="1" ${libraryState.page===pages-1?'disabled':''}>下一页 ${icon('arrow',17)}</button></div>`:'';
}
function catalog(state) {
  const categories=[...new Set(books.map(b=>b.category))];
  return `${header('选择词书','内置词库 · 开源词典整理','library')}<div class="catalog-toolbar"><h2>按目标选择学习范围</h2><button class="text-button" data-action="catalog-close">我的已选词</button></div><div class="scroll-chips">${['全部',...categories].map(category=>`<button data-action="book-category" data-category="${escape(category)}" class="${libraryState.category===category?'selected':''}">${escape(category)}</button>`).join('')}</div><div class="professional-book-list">${books.filter(b=>libraryState.category==='全部'||b.category===libraryState.category).map(b=>`<button class="professional-book" data-action="select-book" data-id="${b.id}"><div class="professional-cover ${b.color}"><small>SHIYU</small><strong>${escape(b.title).replace('英语','<br>英语')}</strong></div><div><h3>${escape(b.title)}</h3><p>${escape(b.subtitle)}</p><span>${b.ids.length.toLocaleString()} 词 · ${state.selectedWords.filter(id=>b.ids.includes(id)).length} 已选</span>${state.selectedBook===b.id?'<small class="current-book-badge">当前词书</small>':''}</div>${icon('arrow',18)}</button>`).join('')}</div><p class="small-note">切换词书只切换学习范围。勾选并确认后才加入已选词，原有记录保留。</p>`;
}
function bookDetail(state) {
  switchDraftBook(state.selectedBook);
  const book=getBook(state.selectedBook);
  const selected=new Set(state.selectedWords);
  const all=book.ids.map(getWord);
  const selectedCount=all.filter(w=>selected.has(w.id)).length;
  let list=all.filter(w=>libraryState.bookTab==='selected'?selected.has(w.id):libraryState.bookTab==='unselected'?!selected.has(w.id):true);
  if(libraryState.query)list=list.filter(w=>w.word.toLowerCase().includes(libraryState.query.toLowerCase())||w.meaning.includes(libraryState.query));
  const groups=[...new Set(list.map(w=>w.word[0].toUpperCase()))].sort();
  const grouping=libraryState.bookTab==='letters';
  const grouped=grouping?list.filter(w=>w.word[0].toUpperCase()===libraryState.letter):list;
  const controls=pagination(grouped.length);
  const current=grouped.slice(libraryState.page*PAGE_SIZE,(libraryState.page+1)*PAGE_SIZE);
  return `<header class="page-header book-detail-header"><button class="icon-button" data-action="catalog-open" aria-label="返回词书目录">${icon('back')}</button><div><h1>${escape(book.title)}</h1><p>${all.length.toLocaleString()} 词 · 内置开源词库</p></div><button class="icon-button" data-action="book-source" aria-label="查看词库来源">${icon('info',20)}</button></header>${libraryState.sourceOpen?`<section class="science-explanation"><h3>词库来源与覆盖</h3><p>${escape(book.sourceNote)}</p><p>释义与音标来自 ${escape(sources[0].title)}，例句如标注“界面示例”，由本界面独立编写。源未提供例句的词条不会自动补造。</p><a href="https://github.com/skywind3000/ECDICT" target="_blank" rel="noopener noreferrer">查看开源词典与 MIT 许可 ↗</a></section>`:''}<form id="book-search" class="search-form"><label class="sr-only" for="book-query">搜索当前词书全部单词</label><input id="book-query" name="query" placeholder="搜索这本词书" value="${escape(libraryState.query)}"><button class="secondary compact">搜索</button></form><div class="book-detail-tabs">${[['unselected','未选',all.length-selectedCount],['selected','已选',selectedCount],['all','全部',all.length],['letters','字母索引',null]].map(([tab,label,count])=>`<button data-action="book-tab" data-tab="${tab}" class="${libraryState.bookTab===tab?'selected':''}">${label}${count!==null?`<small>${count.toLocaleString()}</small>`:''}</button>`).join('')}</div>
  ${grouping?`<p class="letter-index-note">按 A–Z 字母分组，不代表原教材章节。</p><div class="alphabet-index">${groups.map(letter=>`<button data-action="book-letter" data-letter="${letter}" class="${libraryState.letter===letter?'selected':''}">${letter}</button>`).join('')}</div><div class="letter-group-header"><strong>${libraryState.letter} <small>${grouped.length} 词</small></strong><button class="text-button" data-action="select-letter" data-letter="${libraryState.letter}">勾选本组未选词</button></div>`:`<div class="list-meta"><span>${list.length.toLocaleString()} 个结果</span><span>搜索与分页保留勾选</span></div>`}
  <div class="book-select-list">${current.length?current.map(w=>`<div class="book-select-row"><button class="word-checkbox ${libraryState.draft.has(w.id)?'checked':selected.has(w.id)?'already-selected':''}" data-action="book-toggle-word" data-id="${escape(w.id)}" aria-label="${selected.has(w.id)?'已选':libraryState.draft.has(w.id)?'取消勾选':'勾选'} ${escape(w.word)}" aria-pressed="${selected.has(w.id)||libraryState.draft.has(w.id)}" ${selected.has(w.id)?'disabled':''}>${selected.has(w.id)||libraryState.draft.has(w.id)?icon('check',14):''}</button><button class="book-select-word" data-action="open-word" data-id="${escape(w.id)}"><strong>${escape(w.word)}</strong><span>${escape(w.meaning)}</span></button><button class="icon-button" data-action="open-word" data-id="${escape(w.id)}" aria-label="查看 ${escape(w.word)}">${icon('arrow',17)}</button></div>`).join(''):'<div class="empty-state">没有匹配的单词。<p>更换筛选或搜索内容。</p></div>'}</div>${controls}
  <div class="word-selection-footer"><div class="selection-tools"><button data-action="sequential-select">顺选 ${state.learning.newLimit}</button><button data-action="random-select">随机选词</button><button data-action="clear-draft">清空勾选</button></div><button class="primary full" data-action="confirm-words" ${libraryState.draft.size?'':'disabled'}>确认加入 ${libraryState.draft.size} 个词</button><p>仅确认后加入学习范围 · 按每日预算执行</p></div>`;
}
export function render(state) {
  if(libraryState.view==='catalog')return catalog(state);
  if(libraryState.view==='book')return bookDetail(state);
  const book=getBook(state.selectedBook);
  const list=filteredWords(state,libraryState.filter,libraryState.query);
  const controls=pagination(list.length);
  const current=list.slice(libraryState.page*PAGE_SIZE,(libraryState.page+1)*PAGE_SIZE);
  const familiar=state.selectedWords.filter(id=>state.wordStatus[id]==='familiar').length;
  const paused=state.selectedWords.filter(id=>state.wordStatus[id]==='paused').length;
  const active=state.selectedWords.length-familiar-paused;
  return `<header class="page-header library-heading"><div><h1>选词</h1><p>学习范围与你的记录分开管理</p></div><button class="icon-button" data-action="catalog-open" aria-label="选择词书">${icon('plus')}</button></header><button class="selected-book-strip" data-action="open-current-book"><div class="mini-book ${book.color}">${icon('book',26)}</div><div><h2>${escape(book.title)}</h2><p>${book.ids.length.toLocaleString()} 词 · 内置开源词库</p></div>${icon('arrow',18)}</button><div class="library-plan-summary"><div><strong>${state.learning.dailyLimit}<small>词 / 天</small></strong><p>复习 + 新学上限</p></div><div><strong>${({'en-cn':'英 → 中','cn-en':'中 → 英',spell:'拼写',listen:'听辨'})[state.learning.direction]}</strong><p>默认记忆方向</p></div>${go('调整','learning-settings','text-button')}</div><div class="word-status-track"><i class="active" style="width:${active/Math.max(1,state.selectedWords.length)*100}%"></i><i class="familiar" style="width:${familiar/Math.max(1,state.selectedWords.length)*100}%"></i><i class="paused" style="width:${paused/Math.max(1,state.selectedWords.length)*100}%"></i></div><div class="track-legend"><span><i class="dot"></i>活跃 ${active}</span><span><i class="dot blue-dot"></i>用户熟知 ${familiar}</span><span><i class="dot gray"></i>暂停 ${paused}</span></div>
  ${section(`已选单词 <span class="inline-count">${state.selectedWords.length}</span>`,go('开始学习 ↗','learn','text-button'))}<form id="library-search" class="search-form"><label class="sr-only" for="word-search">搜索已选单词</label><input id="word-search" name="query" placeholder="搜索单词或释义" value="${escape(libraryState.query)}"><button class="secondary compact">搜索</button></form><div class="scroll-chips word-filters">${filters.map(([filter,label])=>`<button data-action="word-filter" data-filter="${filter}" class="${libraryState.filter===filter?'selected':''}">${label}</button>`).join('')}</div><div class="list-meta"><span>${list.length.toLocaleString()} 个结果</span><span>熟知属于用户标记</span></div><div id="word-results">${current.length?wordList(current,state):'<div class="empty-state">这个筛选下暂时没有单词。</div>'}</div>${controls}<button class="add-library" data-action="catalog-open">${icon('plus',19)} 从内置词书选词 <span>${books.length} 本预设词库</span></button><details class="library-material"><summary>从个人短文选词</summary><form id="material-form"><label class="field-label" for="material">粘贴一段英文</label><textarea id="material" name="material" rows="4" placeholder="A curious traveler begins a new journey."></textarea><button class="secondary full">提取匹配词并加入</button></form><p class="small-note">只匹配本地词库，不上传文章。</p></details>`;
}
