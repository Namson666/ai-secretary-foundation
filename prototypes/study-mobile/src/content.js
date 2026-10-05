import {vocabularyWords,vocabularyBooks,vocabularySources} from './vocabulary-source.js';
// Hand-authored demonstration content. No paid wordbook, mnemonic, or exam dataset is copied.
const entries = [
  ['ship','/ʃɪp/','n.','船；舰','The ship leaves the harbor at sunrise.','这艘船在日出时离开港口。','水上的交通工具','旅行与出行'],
  ['resilient','/rɪˈzɪliənt/','adj.','有韧性的；能迅速恢复的','Small habits help us become more resilient.','小习惯帮助我们变得更有韧性。','受挫后仍能恢复','成长与生活'],
  ['journey','/ˈdʒɜːrni/','n.','旅行；旅程','Every journey begins with a small step.','每一段旅程都始于一小步。','从出发到到达的过程','旅行与出行'],
  ['transfer','/trænsˈfɜːr/','v.','转移；换乘','We need to transfer to another train.','我们需要换乘另一列火车。','从一个地方到另一个地方','旅行与出行'],
  ['harbor','/ˈhɑːrbər/','n.','港口；避风港','The boats returned to the harbor.','小船回到了港口。','船只停泊的地方','旅行与出行'],
  ['habit','/ˈhæbɪt/','n.','习惯','Reading before bed is a useful habit.','睡前阅读是个有用的习惯。','常常重复做的事','成长与生活'],
  ['improve','/ɪmˈpruːv/','v.','改善；提高','We can improve one small thing today.','今天我们可以改进一件小事。','让某件事变得更好','成长与生活'],
  ['focus','/ˈfoʊkəs/','v.','集中注意力','Focus on one task at a time.','一次专注于一项任务。','把注意力放在一个地方','成长与生活'],
  ['curious','/ˈkjʊriəs/','adj.','好奇的','A curious mind asks good questions.','好奇的头脑会提出好问题。','想知道更多','成长与生活'],
  ['adapt','/əˈdæpt/','v.','适应；调整','Plants adapt to their environment.','植物适应它们的环境。','根据变化调整自己','学术与思考'],
  ['evidence','/ˈevɪdəns/','n.','证据；依据','We need more evidence before deciding.','作出决定前我们需要更多证据。','支持某个判断的信息','学术与思考'],
  ['evaluate','/ɪˈvæljueɪt/','v.','评估；评价','The team will evaluate the new plan.','团队将评估新计划。','仔细判断价值或效果','学术与思考'],
  ['perspective','/pərˈspektɪv/','n.','观点；视角','Try to see it from another perspective.','试着从另一个视角看这件事。','观察事情的角度','学术与思考'],
  ['sustainable','/səˈsteɪnəbl/','adj.','可持续的','Small steps can make learning sustainable.','小步前进能让学习持续下去。','可以长久坚持的','学术与思考'],
  ['destination','/ˌdestɪˈneɪʃən/','n.','目的地','Our next destination is a quiet village.','我们的下一站是一个安静的村庄。','你打算去的地方','旅行与出行'],
  ['reservation','/ˌrezərˈveɪʃən/','n.','预订；预约','I have a reservation for two people.','我有一个两人预订。','提前保留一个位置','旅行与出行'],
  ['explore','/ɪkˈsplɔːr/','v.','探索；探访','We can explore the city on foot.','我们可以步行探索这座城市。','走进未知，发现更多','旅行与出行'],
  ['achieve','/əˈtʃiːv/','v.','实现；达成','Daily practice helps us achieve our goals.','每天练习帮助我们达成目标。','经过努力达到目标','成长与生活'],
];
const richExamples=new Map(entries.map(([word,ipa,type,meaning,example,translation,hint,topic])=>[word,{id:word,word,ipa,type,meaning,example,translation,hint,topic}]));
const normalizeText=value=>String(value??'').replace(/\\r/g,'').trim();
const dictionary=new Map(vocabularyWords.map(entry=>{
  const rich=richExamples.get(entry.id);
  return [entry.id,{...entry,meaning:normalizeText(entry.meaning),definition:normalizeText(entry.definition),
    example:rich?.example??'',translation:rich?.translation??'',hint:rich?.hint??'',
    exampleSource:rich?'界面示例':'',sourceLabel:'ECDICT 开源词典'}];
}));
// Retain existing demonstration cards and their stable IDs when outside the core selections.
for(const [id,rich] of richExamples)if(!dictionary.has(id))dictionary.set(id,{...rich,exampleSource:'界面示例',sourceLabel:'界面示例'});
export const words=[...dictionary.values()];
export const wordIds=words.map(word=>word.id);
export const getWord=id=>dictionary.get(id)??dictionary.get('ship');
export function displayType(word) {return /^(?:n|a|adj|adv|art|v|vi|vt|prep|pron|num|conj|int|abbr|aux|det)\./i.test(word.meaning.trim())?'':word.type;}
export const sources=vocabularySources;
export const books=vocabularyBooks.map(book=>({...book,sourceNote:'ECDICT 开源词典 · MIT 许可 · 按公开词频与标签整理的核心精选，不是完整考试大纲词表。'}));
const bookIndex=new Map(books.map(book=>[book.id,book]));
export const getBook=id=>bookIndex.get(id)??books[0];
export const examQuestions = [
  {prompt:'The ship leaves the ___ at sunrise.',choices:['harbor','habit','answer'],answer:'harbor'},
  {prompt:'“有韧性的；能迅速恢复的”对应哪个词？',choices:['journey','resilient','ship'],answer:'resilient'},
  {prompt:'Every journey begins with a small ___.',choices:['score','voice','step'],answer:'step'},
];
