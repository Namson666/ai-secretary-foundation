import {words} from './content.js';
export function resolveReviewTarget(text,focusWord) {
 const tokens=[...new Set((text.toLowerCase().match(/[a-z][a-z'-]*/g)??[]))];
 if(tokens.some(token=>!words.some(w=>w.id===token))) return {error:'指令包含词库中无法匹配的内容，请明确一个单词，或说“这个词明天练发音”。'};
 if(tokens.length>1) return {error:'这次提到了多个词，请明确一个词，再加入复习。'};
 if(tokens.length===1) return {wordId:tokens[0]};
 if(/这个词|当前词/.test(text))return {wordId:focusWord};
 return {error:'要加入哪个词？可以说“ship 明天练发音”。'};
}
