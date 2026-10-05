// Demonstration visual data only. No personal forgetting model or FSRS computation.
export const chartLabels={day:['08:00','10:00','12:00','14:00','16:00','18:00','20:00'],week:['09/29','09/30','10/01','10/02','10/03','10/04','10/05'],month:['1–5日','6–10日','11–15日','16–20日','21–25日','26–30日']};
function chinaDate(timestamp) {
  if(!Number.isFinite(timestamp))return null;
  const p=Object.fromEntries(new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',hourCycle:'h23'}).formatToParts(new Date(timestamp)).filter(p=>p.type!=='literal').map(p=>[p.type,p.value]));
  return {year:Number(p.year),month:Number(p.month),day:Number(p.day),hour:Number(p.hour),key:`${p.year}-${p.month}-${p.day}`};
}
export function statisticsQuery(state,{tab='forget',period='week',source='sample'},now=Date.now()) {
  if(tab==='forget')return {
    unit:'回忆正确率（%）· 示例',labels:['即刻','1天','2天','4天','7天','14天','30天'],
    series:[{id:'first',label:'首次学习',color:'#cb9854',values:[100,72,58,42,29,18,9]},{id:'second',label:'第二次复习',color:'#738a56',values:[100,89,81,72,61,48,35]},{id:'third',label:'第三次复习',color:'#497d97',values:[100,95,91,86,78,69,56]}],
    max:100,notice:'这组曲线用于展示统计界面，不是个人数据、墨墨算法或已运行的 FSRS 结果。',
  };
  if(tab==='retention')return {
    unit:'词数（个）· 示例分布',labels:['< 1天','1–3天','3–7天','7–14天','14–30天','30天+'],
    series:[{id:'retention',label:'示例记忆持久度',color:'#688f77',values:[2,3,4,4,3,2]}],max:6,
    notice:'持久度模型尚未接入。区间和词数只是图表样例，不是你的记忆预测或能力等级。',
  };
  let labels=chartLabels[period];const current=chinaDate(now);let weekKeys=[];
  if(source==='actual'&&period==='day')labels=['00–04','04–08','08–12','12–16','16–20','20–24'];
  if(source==='actual'&&period==='week'){weekKeys=Array.from({length:7},(_,i)=>new Date(Date.UTC(current.year,current.month-1,current.day-6+i)).toISOString().slice(0,10));labels=weekKeys.map(key=>key.slice(5).replace('-','/'));}
  const length=labels.length;
  const sampleNew=[12,8,15,10,6,18,9].slice(0,length);
  const sampleReview=[23,29,20,32,27,30,24].slice(0,length);
  const actualNew=Array(length).fill(0),actualReview=Array(length).fill(0);
  state.completed.forEach(attempt=>{
    const date=chinaDate(attempt.at);if(!date)return;let bucket=-1;
    if(period==='day'&&date.key===current.key)bucket=Math.min(5,Math.floor(date.hour/4));
    if(period==='week')bucket=weekKeys.indexOf(date.key);
    if(period==='month'&&date.year===current.year&&date.month===current.month)bucket=Math.min(5,Math.floor((date.day-1)/5));
    if(bucket<0)return;if(attempt.isReview)actualReview[bucket]++;else actualNew[bucket]++;
  });
  const useSample=source==='sample';
  return {unit:useSample?'样例任务数（项）':'浏览器演示尝试数（次）',labels,series:[{id:'new',label:useSample?'新学样例':'学习尝试',color:'#728eaa',values:useSample?sampleNew:actualNew},{id:'review',label:useSample?'复习样例':'复习尝试',color:'#78976c',values:useSample?sampleReview:actualReview}],max:Math.max(50,state.completed.length+5),notice:useSample?'示例趋势帮助你体验日期、图例和范围切换，不代表真实学习记录。':'按上海时间汇总此浏览器的演示尝试，不代表真实 App 学习统计或掌握率。'};
}
