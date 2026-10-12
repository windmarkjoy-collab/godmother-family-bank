export const roundYuan = value => Math.floor(value + .5 + Number.EPSILON);
export const interest = (principal,rate,days) => principal * rate * days / 365;
export const loanLimit = ({cash,deposits,capital,loans,allowance}) => Math.max(0,Math.floor(Math.min(200,allowance*.25,cash-deposits-10,capital*.1-loans)));
export const equation = entries => entries.reduce((s,e)=>({cash:s.cash+e.cash,loans:s.loans+e.loans,deposits:s.deposits+e.deposits,equity:s.equity+e.equity}),{cash:0,loans:0,deposits:0,equity:0});
