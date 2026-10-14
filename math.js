export const roundYuan = value => Math.floor(value + .5 + Number.EPSILON);
export const interest = (principal,rate,days) => principal * rate * days / 365;
export const maturityDate = (date,months) => {
 const [y,m,d]=date.split('-').map(Number),first=new Date(Date.UTC(y,m-1+months,1));
 const last=new Date(Date.UTC(first.getUTCFullYear(),first.getUTCMonth()+1,0)).getUTCDate();
 first.setUTCDate(Math.min(d,last));return first.toISOString().slice(0,10);
};
export const loanLimit = ({cash,deposits,capital,loans,allowance}) => Math.max(0,Math.floor(Math.min(200,allowance*.25,cash-deposits-10,capital*.1-loans)));
export const equation = entries => entries.reduce((s,e)=>({cash:s.cash+e.cash,loans:s.loans+e.loans,deposits:s.deposits+e.deposits,equity:s.equity+e.equity}),{cash:0,loans:0,deposits:0,equity:0});
