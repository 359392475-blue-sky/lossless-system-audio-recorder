import { readFileSync } from 'node:fs';
const escape=s=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const issues='https://github.com/359392475-blue-sky/lossless-system-audio-recorder/issues';
const privacy=readFileSync(new URL('./public/privacy.md',import.meta.url),'utf8');
const license=readFileSync(new URL('./public/LICENSE.txt',import.meta.url),'utf8');
const pages={
 '/': ['无损系统录音机','<p>在 Mac 上录制系统播放的声音，导出无损 ALAC 音频。音频始终在本机处理。</p><p>每次开始录音需联网验证版本。免登录可完成五次成功录音；邀请两台有效新设备完成下载、激活和首次成功录音后，解锁当前版本系列无限免费使用。</p><p><a href="/download?channel=website">下载 Mac 版</a></p><p>需要 macOS 14.2 或更新版本。首次使用需允许系统音频录制权限。</p>'],
 '/privacy':['隐私与联网说明',`<pre>${escape(privacy)}</pre>`],
 '/license':['软件使用许可',`<pre>${escape(license)}</pre>`],
 '/support':['反馈与权益帮助',`<p>录音次数异常、邀请未生效或需要处理设备数据，可通过项目反馈入口联系维护者。</p><p><a href="${issues}" rel="noreferrer">打开 GitHub Issues 反馈</a></p><p>这是公开页面。请仅描述问题、应用版本、发生时间与屏幕上的错误文字；不要提交音频、个人资料、完整日志、设备摘要、私钥或邀请激活凭证。</p><p>次数结算失败时，先保持联网并重新打开应用等待同步。不要反复卸载或清理钥匙串，以免丢失权益凭据。</p><p>邀请需由两台有效新设备分别完整下载、绑定并首次成功生成录音；重复安装或仅下载不会增加人数。</p><p>需要处理设备数据时，请先只说明请求类型，等待维护者提供适合的核实方式。删除身份可能影响权益恢复；服务不会自动清空数据或重置额度。</p>`]
};
export function handlePublicPages(req,res,url){
 if(!Object.hasOwn(pages,url.pathname))return false;const page=pages[url.pathname];
 if(!['GET','HEAD'].includes(req.method)){res.writeHead(405,{'Allow':'GET, HEAD','Cache-Control':'no-store'});res.end();return true;}
 res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"});
 res.end(req.method==='HEAD'?undefined:`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${page[0]} · 无损系统录音机</title><style>body{font:17px/1.8 system-ui,sans-serif;max-width:760px;margin:48px auto;padding:0 24px;color:#17272b;background:#f7f9f8}a{color:#146653}h1{font-size:30px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit}nav{border-top:1px solid #cdd8d3;margin-top:32px;padding-top:20px}</style><main><h1>${page[0]}</h1>${page[1]}</main><nav><a href="/">下载</a> · <a href="/privacy">隐私</a> · <a href="/license">许可</a> · <a href="/support">反馈与权益帮助</a></nav></html>`);return true;
}
