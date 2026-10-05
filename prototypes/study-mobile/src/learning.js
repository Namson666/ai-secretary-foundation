// Independence is a claim captured before revealing the answer, never inferred later.
export function canRateIndependent(attempt) {return attempt.result==='self-recalled'&&!attempt.hinted;}

export function setRecallDirection(session,direction) {
  if(!['en-cn','cn-en'].includes(direction))return;
  session.direction=direction;
  // Direction changes keep the same meaning-review ownership; skill changes release it.
  if(session.mode!=='recall')session.reviewId=null;
  session.mode='recall';
}
