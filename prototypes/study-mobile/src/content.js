// Hand-authored sample content; no commercial wordbook or exam dataset is copied.
export const words = [
  {id:'ship',word:'ship',ipa:'/ʃɪp/',type:'n.',meaning:'船；舰',example:'The ship leaves the harbor at sunrise.',translation:'这艘船在日出时离开港口。',hint:'一种在水上航行的交通工具',topic:'旅行与出行'},
  {id:'resilient',word:'resilient',ipa:'/rɪˈzɪliənt/',type:'adj.',meaning:'有韧性的；能迅速恢复的',example:'Small habits help us become more resilient.',translation:'小习惯帮助我们变得更有韧性。',hint:'受到挫折后，仍然能恢复过来',topic:'成长与生活'},
  {id:'journey',word:'journey',ipa:'/ˈdʒɜːrni/',type:'n.',meaning:'旅行；旅程',example:'Every journey begins with a small step.',translation:'每一段旅程都始于一小步。',hint:'从出发到到达的过程',topic:'旅行与出行'},
];
export const getWord = id => words.find(word => word.id === id) ?? words[0];
export const examQuestions = [
  {prompt:'The ship leaves the ___ at sunrise.',choices:['harbor','habit','answer'],answer:'harbor'},
  {prompt:'“有韧性的；能迅速恢复的”对应哪个词？',choices:['journey','resilient','ship'],answer:'resilient'},
  {prompt:'Every journey begins with a small ___.',choices:['score','voice','step'],answer:'step'},
];
