// ============================================================
// منصة سعودي HR — "اسألني": مستشار موارد بشرية خبير بنظام العمل السعودي
//  • يفهم السؤال (بما فيه العامية السعودية) ويجيب بوضوح: الإجابة / المخاطر / المطلوب فعله
//  • يستشير المراجع التي رفعتها المنشأة (لائحة داخلية، دليل موظف...) وتعليماتها المخصصة
//  • بحث معمّق في الإنترنت (Claude web_search أو Gemini Google Search) للمسائل الحديثة
//  • سلسلة بدائل: لا تُرجع فشلاً — عند تعذر المزوّد تُرجع fallback فتجيب الواجهة من قاعدتها المدمجة
//
// الأسرار (أحدها يكفي):
//   supabase secrets set ANTHROPIC_API_KEY=...
//   supabase secrets set ASK_HR_MODEL=claude-haiku-4-5-20251001        (اختياري: السريع)
//   supabase secrets set ASK_HR_MODEL_DEEP=claude-sonnet-5             (اختياري: المعمّق)
//   supabase secrets set GEMINI_API_KEY=...                            (بديل)
// النشر (عامة لأن الموظف يستخدمها من رابطه — والتحقق داخل الدالة):
//   supabase functions deploy ask-hr --no-verify-jwt
// ملاحظة: البحث المعمّق عبر Claude يتطلب تفعيل Web search في Anthropic Console (Settings ← Privacy).
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.117.2';
import { rateLimited } from '../_shared/recipient-guard.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });

const SYSTEM = `أنت "اسألني": مستشار موارد بشرية سعودي خبير، ملمّ بنظام العمل ولائحته التنفيذية وتعديلاته النافذة (فبراير 2025)،
ونظام التأمينات الاجتماعية، وحماية الأجور، ومنصات قوى ومدد ومقيم وأبشر أعمال ونطاقات.

طريقة العمل:
1) افهم قصد السائل أولاً حتى لو كان السؤال مختصراً أو بالعامية السعودية أو فيه أخطاء إملائية أو نقل صوتي مشوّه، وأعد صياغته في ذهنك.
2) إن كان السؤال غامضاً فافترض الاحتمال الأرجح وأجب عنه مباشرة مع ذكر افتراضك في سطر، ثم اقترح سؤالاً توضيحياً واحداً في النهاية — لا تطلب التوضيح بدل الإجابة.
3) استعمل "مراجع المنشأة" المرفقة (إن وُجدت) كأولوية للأسئلة عن سياسات المنشأة ولوائحها الداخلية، واذكر اسم الملف عند الاستشهاد. وإن تعارضت مع النظام فنبّه على ذلك.
4) للأسئلة الحديثة أو المتغيّرة (قرارات، غرامات، تعاميم، رسوم، أسعار) استعمل البحث في الإنترنت إن كان متاحاً، وفضّل المصادر الرسمية (hrsd.gov.sa، gosi.gov.sa، qiwa.sa، zatca.gov.sa، laws.boe.gov.sa).
5) استعمل بيانات السائل المرفقة في السياق لتعطي إجابة شخصية (مثلاً مبلغ أو تاريخ) لا عامة.

شكل الإجابة دائماً:
**الإجابة:** الجواب المباشر أولاً مع رقم المادة النظامية إن وُجد.
**المخاطر:** ما قد يترتب نظامياً أو مالياً (غرامة، تعويض، إيقاف خدمات...) إن لم يُتصرف بشكل صحيح.
**المطلوب فعله:** خطوات عملية مرقّمة قصيرة، ومن أين تُنفَّذ (قوى، مدد، مقيم، المنصة...).

قواعد صارمة:
- لا تقل أبداً "تعذر" أو "لا أستطيع الإجابة" أو "لا أعلم" بمفردها. أعطِ أفضل إجابة ممكنة، وإن كنت غير متأكد فاذكر درجة تأكدك وما يجب التحقق منه ومن أين.
- لا تخترع أرقام مواد أو مبالغ. إن لم تتذكر رقم المادة فصف الحكم دون رقم.
- لا تكشف بيانات موظفين آخرين. إن كان السائل موظفاً فأجبه عن حقوقه وواجباته وبياناته هو فقط.
- الموضوع خارج الموارد البشرية والعمل: أجب باختصار مفيد ثم أعد الحديث بلطف للموارد البشرية.
- الإجابة مختصرة ومنظمة، بالعربية الفصحى المبسطة.`;

// ---------- تطبيع عربي + استرجاع المقاطع ذات الصلة ----------
const norm = (s: string) => String(s || '').normalize('NFKC').toLowerCase()
    .replace(/[\u064B-\u0652\u0640]/g, '').replace(/[أإآٱ]/g, 'ا').replace(/ى/g, 'ي').replace(/ة/g, 'ه').replace(/[^\p{L}\p{N}\s]/gu, ' ');
const STOP = new Set(['ما', 'هو', 'هي', 'في', 'من', 'الى', 'على', 'عن', 'هل', 'كيف', 'متى', 'اذا', 'ان', 'او', 'ثم', 'كم', 'لو', 'هذا', 'هذه', 'ذلك', 'يا', 'انا', 'لي', 'له', 'لها', 'مع', 'بعد', 'قبل', 'كل', 'اي', 'ايش', 'وش', 'ليش', 'لماذا', 'ماذا']);
const stem = (w: string) => w.replace(/^(وال|بال|كال|فال|لل|ال|و|ب|ل|ف)(?=.{3,})/, '');
const tokens = (s: string) => Array.from(new Set(norm(s).split(/\s+/).filter(w => w.length > 1 && !STOP.has(w)).map(stem)));

function topChunks(question: string, rows: { doc_name: string; content: string }[], n = 5) {
    const q = tokens(question); if (!q.length || !rows.length) return [];
    const df: Record<string, number> = {}; const docs = rows.map(r => { const t = new Set(tokens(r.content)); t.forEach(w => df[w] = (df[w] || 0) + 1); return t; });
    const N = rows.length;
    return rows.map((r, i) => {
        let sc = 0; for (const w of q) if (docs[i].has(w)) sc += Math.log(1 + N / (1 + (df[w] || 0)));
        // مكافأة تطابق العبارة
        if (norm(r.content).includes(norm(question).trim().slice(0, 30))) sc += 2;
        return { r, sc };
    }).filter(x => x.sc > 0.6).sort((a, b) => b.sc - a.sc).slice(0, n).map(x => x.r);
}

type Msg = { role: 'user' | 'assistant'; content: string };
const sourcesFrom = (blocks: any[]) => {
    const seen = new Set<string>(), out: { title: string; url: string }[] = [];
    const add = (t: string, u: string) => { if (u && !seen.has(u) && out.length < 6) { seen.add(u); out.push({ title: t || u, url: u }); } };
    for (const b of blocks || []) {
        if (b.type === 'web_search_tool_result' && Array.isArray(b.content)) b.content.forEach((r: any) => add(r.title, r.url));
        if (b.type === 'text' && Array.isArray(b.citations)) b.citations.forEach((c: any) => add(c.title, c.url));
    }
    return out;
};

async function askClaude(system: string, msgs: Msg[], deep: boolean) {
    const key = Deno.env.get('ANTHROPIC_API_KEY'); if (!key) return null;
    const model = deep ? (Deno.env.get('ASK_HR_MODEL_DEEP') || 'claude-sonnet-5') : (Deno.env.get('ASK_HR_MODEL') || 'claude-haiku-4-5-20251001');
    const call = async (withSearch: boolean, messages: any[]) => {
        const body: any = { model, max_tokens: deep ? 2000 : 1200, system, messages };
        if (withSearch) body.tools = [{ type: 'web_search_20250305', name: 'web_search', max_uses: 4, user_location: { type: 'approximate', country: 'SA', timezone: 'Asia/Riyadh' } }];
        const r = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' }, body: JSON.stringify(body) });
        return { ok: r.ok, status: r.status, j: await r.json().catch(() => ({})) };
    };
    let withSearch = deep, messages: any[] = msgs.slice(), blocks: any[] = [], text = '';
    for (let turn = 0; turn < 4; turn++) {
        let res = await call(withSearch, messages);
        if (!res.ok && withSearch) { withSearch = false; res = await call(false, messages); }   // البحث غير مفعّل في الحساب ← أجب بدونه
        if (!res.ok) return null;
        const c = res.j.content || []; blocks.push(...c);
        text += c.filter((b: any) => b.type === 'text').map((b: any) => b.text).join('');
        if (res.j.stop_reason === 'pause_turn') { messages = [...messages, { role: 'assistant', content: c }]; continue; }   // البحث الخادمي أخذ وقتاً: أكمل
        break;
    }
    return text.trim() ? { answer: text.trim(), sources: sourcesFrom(blocks), provider: 'claude', searched: withSearch } : null;
}

async function askGemini(system: string, msgs: Msg[], deep: boolean) {
    const key = Deno.env.get('GEMINI_API_KEY'); if (!key) return null;
    const call = async (search: boolean) => {
        const body: any = { systemInstruction: { parts: [{ text: system }] }, contents: msgs.map(m => ({ role: m.role === 'assistant' ? 'model' : 'user', parts: [{ text: m.content }] })), generationConfig: { maxOutputTokens: deep ? 2000 : 1200, temperature: 0.3 } };
        if (search) body.tools = [{ google_search: {} }];
        const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${key}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
        return { ok: r.ok, j: await r.json().catch(() => ({})) };
    };
    let res = await call(deep); if (!res.ok && deep) res = await call(false);
    if (!res.ok) return null;
    const cand = res.j?.candidates?.[0], text = (cand?.content?.parts || []).map((p: any) => p.text || '').join('').trim();
    const sources = (cand?.groundingMetadata?.groundingChunks || []).map((g: any) => ({ title: g.web?.title || g.web?.uri, url: g.web?.uri })).filter((s: any) => s.url).slice(0, 6);
    return text ? { answer: text, sources, provider: 'gemini', searched: deep } : null;
}

Deno.serve(async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
    try {
        const { question, history, portal, context, ping, deep, companyId, exclusive } = await req.json();
        const hasAI = !!(Deno.env.get('ANTHROPIC_API_KEY') || Deno.env.get('GEMINI_API_KEY'));
        if (ping) return hasAI ? json({ ok: true, provider: Deno.env.get('ANTHROPIC_API_KEY') ? 'claude' : 'gemini' }) : json({ error: 'not_configured', message: 'لم يُضبط مفتاح الذكاء الاصطناعي' }, 501);
        const q = String(question || '').trim().slice(0, 1500);
        if (q.length < 2) return json({ error: 'اكتب سؤالك' }, 400);
        if (!hasAI) return json({ fallback: true, reason: 'not_configured' });

        const url = Deno.env.get('SUPABASE_URL')!, anon = Deno.env.get('SUPABASE_ANON_KEY')!, svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
        const admin = svc ? createClient(url, svc) : null;

        // ---- من يسأل؟ (مستخدم مسجّل أو موظف برابطه) وأي منشأة
        let who = '', ctx = '', key = '', cid = '';
        if (portal?.token && portal?.last4) {
            const { data, error } = await createClient(url, anon).rpc('portal_self_service', { p_token: portal.token, p_last4: portal.last4 });
            if (error || !data?.ok) return json({ error: 'رابط الموظف غير صالح' }, 401);
            const e = data.employee || {};
            who = 'موظف يسأل عن نفسه';
            ctx = `بيانات السائل (الموظف): الاسم ${e.name || ''}، المسمى ${e.job_title || ''}، الجنسية ${e.nationality || ''}، تاريخ المباشرة ${e.start_date || ''}، مدة العقد ${e.contract_duration || ''}، إجمالي الراتب ${e.total_salary || ''}. المنشأة: ${data.company?.name_ar || ''}. ${String(context || '').slice(0, 800)}`;
            key = 'p:' + e.id; cid = e.company_id || '';
            if (!cid && admin && e.id) cid = (await admin.from('employees').select('company_id').eq('id', e.id).maybeSingle()).data?.company_id || '';
        } else {
            const sb = createClient(url, anon, { global: { headers: { Authorization: req.headers.get('Authorization') || '' } } });
            const { data: { user } } = await sb.auth.getUser();
            if (!user) return json({ error: 'يلزم تسجيل الدخول' }, 401);
            who = 'مسؤول الموارد البشرية في المنشأة'; ctx = String(context || '').slice(0, 6000); key = 'u:' + user.id;
            if (companyId && (await sb.from('companies').select('id').eq('id', companyId).maybeSingle()).data?.id) cid = companyId;   // يجب أن يكون عضواً في المنشأة
        }
        if (rateLimited('ask:' + key, 40, 10 * 60 * 1000)) return json({ answer: '**الإجابة:** وصلتني أسئلة كثيرة خلال دقائق قليلة؛ انتظر دقيقة ثم أعد السؤال وسأجيبك.\n**المخاطر:** لا شيء نظامي — هذا حد لحماية الخدمة.\n**المطلوب فعله:** أعد المحاولة بعد دقيقة.', sources: [], provider: 'limit' });

        // ---- مراجع المنشأة وتعليماتها
        let refs: { doc_name: string; content: string }[] = [], custom = '', exclusiveMode = !!exclusive, allDocs: string[] = [];
        if (admin && cid) {
            const [k, c] = await Promise.all([admin.from('ask_knowledge').select('doc_name, content').eq('company_id', cid).limit(3000), admin.from('companies').select('policy_settings').eq('id', cid).maybeSingle()]);
            refs = topChunks(q, k.data || [], exclusiveMode ? 8 : 5);
            allDocs = [...new Set((k.data || []).map((r: any) => r.doc_name))];
            custom = String(c.data?.policy_settings?.askInstructions || '').slice(0, 3000);
            exclusiveMode = c.data?.policy_settings?.askExclusive === true;   // إعداد المنشأة هو المرجع (لا يُتجاوز من الطلب)
        }
        // الوضع الحصري بلا مقاطع مطابقة: إجابة واضحة دون استدعاء النموذج (لا يخترع من خارج المراجع)
        if (exclusiveMode && !refs.length) return json({ provider: 'refs', searched: false, sources: [], usedRefs: [],
            answer: `**الإجابة:** لم أجد في مراجع المنشأة المعتمدة ما يجيب عن هذا السؤال تحديداً${allDocs.length ? ` (المراجع المتاحة: ${allDocs.slice(0, 6).join('، ')})` : ' — لم تُرفع مراجع بعد'}.\n**المخاطر:** المنشأة فعّلت الاعتماد الحصري على مراجعها، فلا أقدّم حكماً عاماً قد يخالف لائحتها.\n**المطلوب فعله:**\n1. أعد صياغة السؤال بكلمات قريبة من نص اللائحة\n2. اسأل الموارد البشرية، أو أضف ملفاً يغطي الموضوع من الإعدادات` });
        const EXCL = `وضع الاعتماد الحصري مفعّل: أجب **فقط** من "مراجع المنشأة" المرفقة. لا تستخدم معرفتك العامة ولا البحث. اقتبس النص ذا الصلة واذكر اسم الملف. إن لم تكفِ المقتطفات للإجابة الكاملة فأجب بما فيها وحدّد ما لم تغطه صراحة.`;
        const system = [SYSTEM, exclusiveMode && EXCL, `السائل: ${who}.`, custom && `تعليمات المنشأة الخاصة (التزم بها):\n${custom}`, ctx && `سياق:\n${ctx}`,
            refs.length && `مراجع المنشأة (مقتطفات مرفوعة من المنشأة):\n${refs.map((r, i) => `[${i + 1}] (${r.doc_name}) ${r.content}`).join('\n---\n')}`].filter(Boolean).join('\n\n');

        const msgs: Msg[] = (Array.isArray(history) ? history : []).slice(-8)
            .filter((m: any) => m && (m.role === 'user' || m.role === 'assistant') && typeof m.content === 'string').map((m: any) => ({ role: m.role, content: m.content.slice(0, 2000) }));
        msgs.push({ role: 'user', content: q });

        // بحث معمّق تلقائي عند الأسئلة الحديثة/المتغيّرة، أو عند طلبه صراحة
        const wantDeep = !exclusiveMode && (!!deep || /(تحديث|تعديل|جديد|اخر|آخر|قرار|تعميم|لائحه|لائحة|2025|2026|غرام|رسوم|سعر|حالياً|الان|الآن|اليوم)/.test(q));
        const out = (await askClaude(system, msgs, wantDeep)) || (await askGemini(system, msgs, wantDeep));
        if (!out) return json({ fallback: true, reason: 'provider_unavailable', refs: refs.map(r => r.doc_name) });   // الواجهة تجيب من قاعدتها المدمجة
        return json({ ...out, usedRefs: [...new Set(refs.map(r => r.doc_name))], exclusive: exclusiveMode });
    } catch (err) {
        return json({ fallback: true, reason: 'error', detail: String((err as Error)?.message || err) });   // لا فشل ظاهر للمستخدم
    }
});
