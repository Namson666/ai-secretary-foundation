// Independence is a claim captured before revealing the answer, never inferred later.
export function canRateIndependent(attempt) {return attempt.result==='self-recalled'&&!attempt.hinted;}
