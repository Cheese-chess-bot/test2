/** This fork never contacts hosted Intelligence. All model calls must use OpenRouter. */
const originalFetch=globalThis.fetch;
const forbidden=new Set(['api.openai.com','api.anthropic.com','generativelanguage.googleapis.com','api.x.ai','api.moonshot.ai']);
globalThis.fetch=async (input,init)=>{
 const value=input instanceof Request?input.url:String(input);
 const url=new URL(value);
 if(url.hostname==='copilotkit.ai'||url.hostname.endsWith('.copilotkit.ai')||forbidden.has(url.hostname))
  throw new Error('Jevie local mode blocks hosted Intelligence and direct model providers');
 if(process.env.OPENBOT_OFFLINE==='true' && !['127.0.0.1','localhost','[::1]'].includes(url.hostname))
  throw new Error('Offline demo makes no external HTTP requests');
 return originalFetch(input,init);
};
