-- ============================================================
-- منصة سعودي HR — ملف الربط الموحّد لقاعدة البيانات (Supabase)
-- يجمع كل ملفات الترحيل بالترتيب الصحيح، وآمن لإعادة التشغيل أكثر من مرة
-- (if not exists / create or replace / drop policy if exists).
--
-- التشغيل: Supabase Studio → SQL Editor → الصق الملف كاملاً → Run
-- ثم: Settings → Data API → تأكد أن الجداول والدوال التالية ضمن Exposed:
--   الجداول: departments, document_templates, salary_adjustments, employee_documents,
--            hr_operations, employee_requests, employee_attendance
--   الدوال: next_employee_number, portal_self_service, portal_submit_request,
--           portal_cancel_request, portal_punch
--
-- ملاحظة: دوال البوابة الأصلية (portal_open / portal_record_upload / portal_token_valid)
-- مستثناة عمداً حتى لا تُستبدل النسخة المنشورة والعاملة حالياً لديك.
-- ============================================================

-- ============================================================
-- تصفية إعدادات المنشأة المُرسلة لرابط الموظف: قائمة بيضاء بما يحتاجه الموظف فقط
-- (كانت الدالة تُرسل كل الإعدادات: بصمة الرقم السري، رابط الأتمتة، أسماء دخول المنصات الحكومية، تعليمات المساعد...)
-- ============================================================
create or replace function public.portal_safe_settings(p jsonb)
returns jsonb language sql immutable set search_path = public as $$
    select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
      from jsonb_each(coalesce(p, '{}'::jsonb)) as t(k, v)
     where k = any (array['gosi', 'leavesPaid', 'leavesPaidNoBalance', 'leavesUnpaid', 'permissions', 'banks', 'customBanks', 'geo', 'companyDocs', 'askExclusive']);
$$;

-- ############################################################
-- migration_portal_archive.sql
-- ############################################################
-- ============================================================
-- migration_portal_archive.sql
-- ميزتان: (1) أرشفة الموظفين المنتهية خدمتهم
--          (2) بوابة الموظف الخارجية لرفع المستندات (بدون تسجيل دخول)
-- ينفَّذ في Supabase SQL Editor مرة واحدة
-- ============================================================

-- ------------------------------------------------------------
-- 1) أعمدة الأرشفة على جدول employees
-- ------------------------------------------------------------
alter table public.employees add column if not exists is_archived boolean not null default false;
alter table public.employees add column if not exists archived_at timestamptz;

create index if not exists idx_employees_is_archived on public.employees(is_archived);

-- ------------------------------------------------------------
-- 2) أعمدة بوابة الموظف على جدول employees
-- ------------------------------------------------------------
alter table public.employees add column if not exists portal_token text;
alter table public.employees add column if not exists portal_enabled boolean not null default false;

-- فهرس فريد جزئي: كل توكن بوابة يجب أن يكون فريداً بين كل الموظفين
create unique index if not exists idx_employees_portal_token
    on public.employees(portal_token)
    where portal_token is not null;

-- ------------------------------------------------------------
-- 3) جدول مستندات بوابة الموظف
-- ------------------------------------------------------------
create table if not exists public.employee_documents (
    id          uuid primary key default gen_random_uuid(),
    employee_id uuid not null references public.employees(id) on delete cascade,
    doc_key     text not null,          -- مفتاح نوع المستند (مثل: national_id, photo, contract...)
    stage_id    integer,                -- رقم مرحلة الإلحاق المرتبطة بهذا المستند، إن وُجدت
    file_name   text not null,
    file_path   text not null,          -- المسار داخل حاوية التخزين employee-docs
    uploaded_at timestamptz not null default now()
);

create index if not exists idx_employee_documents_employee on public.employee_documents(employee_id);

-- كل موظف له نسخة واحدة فقط لكل نوع مستند: رفع جديد يستبدل القديم منطقياً عبر upsert من الدالة أدناه
create unique index if not exists idx_employee_documents_unique_key
    on public.employee_documents(employee_id, doc_key);

alter table public.employee_documents enable row level security;

-- صاحب المنشأة (صاحب الحساب) يرى مستندات موظفيه فقط، عبر ربط غير مباشر بجدول employees
drop policy if exists "owner can view employee documents" on public.employee_documents;
create policy "owner can view employee documents"
    on public.employee_documents for select
    using (
        exists (
            select 1 from public.employees e
            where e.id = employee_documents.employee_id
              and e.owner_id = auth.uid()
        )
    );

-- لا سياسة insert/update عادية هنا: كل الكتابة تمر حصراً عبر دالة portal_record_upload
-- الموقّعة بصلاحيات SECURITY DEFINER أدناه، حماية من أي كتابة مباشرة غير موثّقة بالتوكن.

-- ------------------------------------------------------------
-- 4) حاوية التخزين (Storage bucket) لملفات البوابة
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('employee-docs', 'employee-docs', false)
on conflict (id) do nothing;

-- سياسة تسمح بالرفع (insert) لأي طلب يستخدم مفتاح anon، لأن بوابة الموظف تعمل بدون تسجيل دخول.
-- الحماية الفعلية من إساءة الاستخدام تقع على مستوى التطبيق (معرفة التوكن + آخر 4 أرقام هوية)
-- ثم تُسجَّل عبر portal_record_upload فقط، وليس عبر هذه السياسة مباشرة.
drop policy if exists "anon can upload to employee-docs" on storage.objects;
create policy "anon can upload to employee-docs"
    on storage.objects for insert
    with check (bucket_id = 'employee-docs');

drop policy if exists "owner can read employee-docs" on storage.objects;
create policy "owner can read employee-docs"
    on storage.objects for select
    using (
        bucket_id = 'employee-docs'
        and exists (
            select 1 from public.employees e
            where e.owner_id = auth.uid()
              and storage.objects.name like 'portal/' || e.portal_token || '/%'
        )
    );

-- ------------------------------------------------------------
-- 5) دالة portal_open: تتحقق من التوكن + آخر 4 أرقام هوية،
--    وتُرجع بيانات الموظف اللازمة لعرض بوابته إن كانت صحيحة.
--    SECURITY DEFINER: تتجاوز RLS عمداً لأن البوابة تعمل بدون تسجيل دخول (auth.uid() فارغ).
-- ------------------------------------------------------------
-- (مستثنى: portal_open — تبقى النسخة المنشورة)
-- ------------------------------------------------------------
-- 6) دالة portal_record_upload: تسجّل مستنداً مرفوعاً بعد التحقق
--    من نفس التوكن وآخر 4 أرقام هوية مرة أخرى (دفاع مزدوج).
-- ------------------------------------------------------------
-- (مستثنى: portal_record_upload — تبقى النسخة المنشورة)
-- ------------------------------------------------------------
-- 7) دالة اختيارية: التحقق من صلاحية توكن دون كشف بيانات (تُستخدم لفحوصات سريعة عند الحاجة)
-- ------------------------------------------------------------
-- (مستثنى: portal_token_valid — تبقى النسخة المنشورة)

-- ############################################################
-- migration_departments_hierarchy.sql
-- ############################################################
-- ============================================================
-- migration_departments_hierarchy.sql
-- نظام الأقسام/الإدارات + المدير المباشر + الرقم الوظيفي المتسلسل لكل قسم
-- ============================================================

-- ------------------------------------------------------------
-- 1) جدول الأقسام/الإدارات
-- ------------------------------------------------------------
create table if not exists public.departments (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null references public.companies(id) on delete cascade,
    owner_id        uuid not null references auth.users(id) on delete cascade,
    name            text not null,                 -- اسم القسم الكامل، مثال: "تقنية المعلومات"
    code_prefix     text not null,                 -- اختصار يُستخدم في الرقم الوظيفي، مثال: "IT"
    next_seq        integer not null default 1,    -- العدّاد التالي المتاح لهذا القسم (يُستهلك تلقائياً)
    created_at      timestamptz not null default now()
);

-- كل منشأة لا يمكن أن يتكرر فيها نفس اختصار القسم (بصرف النظر عن حالة الأحرف)
create unique index if not exists idx_departments_unique_prefix
    on public.departments(company_id, upper(code_prefix));

create index if not exists idx_departments_company on public.departments(company_id);

alter table public.departments enable row level security;

drop policy if exists "select own departments" on public.departments;
create policy "select own departments"
    on public.departments for select using (auth.uid() = owner_id);
drop policy if exists "insert own departments" on public.departments;
create policy "insert own departments"
    on public.departments for insert with check (auth.uid() = owner_id);
drop policy if exists "update own departments" on public.departments;
create policy "update own departments"
    on public.departments for update using (auth.uid() = owner_id);
drop policy if exists "delete own departments" on public.departments;
create policy "delete own departments"
    on public.departments for delete using (auth.uid() = owner_id);

-- ------------------------------------------------------------
-- 2) ربط الموظف بالقسم والمدير المباشر
-- ------------------------------------------------------------
alter table public.employees add column if not exists department_id uuid references public.departments(id) on delete set null;
alter table public.employees add column if not exists manager_id    uuid references public.employees(id) on delete set null;

create index if not exists idx_employees_department on public.employees(department_id);
create index if not exists idx_employees_manager on public.employees(manager_id);

-- ------------------------------------------------------------
-- 3) دالة توليد الرقم الوظيفي التالي لقسم معيّن بأمان
--    (تستخدم قفل صف للتعامل الآمن مع الطلبات المتزامنة، فلا يتكرر أي رقم)
-- ------------------------------------------------------------
create or replace function public.next_employee_number(p_department_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
    v_prefix text;
    v_seq    integer;
begin
    select code_prefix, next_seq into v_prefix, v_seq
    from public.departments
    where id = p_department_id
    for update;              -- قفل الصف: يمنع طلبين متزامنين من الحصول على نفس الرقم

    if v_prefix is null then
        return null;
    end if;

    update public.departments set next_seq = v_seq + 1 where id = p_department_id;

    return v_prefix || '-' || lpad(v_seq::text, 3, '0');   -- مثال: IT-001
end;
$$;

-- ############################################################
-- migration_document_templates.sql
-- ############################################################
-- ============================================================
-- migration_document_templates.sql
-- قوالب تنسيق مستندات PDF (عرض وظيفي، مخالصة، تقارير...)
-- لكل منشأة عدة قوالب محفوظة + قالب واحد "مفعّل" في كل لحظة
-- ============================================================

create table if not exists public.document_templates (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid not null references public.companies(id) on delete cascade,
    owner_id        uuid not null references auth.users(id) on delete cascade,
    name            text not null default 'قالب جديد',
    base_style      text not null default 'modern' check (base_style in ('simple', 'modern', 'classic')),
    is_active       boolean not null default false,   -- القالب المفعّل حالياً لهذه المنشأة (واحد فقط)

    -- إعدادات الرأس والتذييل (نصوص حرة يدخلها المستخدم)
    header_text     text not null default '',
    footer_text     text not null default '',

    -- إحداثيات حرة (بالنسبة المئوية من أبعاد الصفحة، 0-100) لعناصر الصفحة القابلة للسحب
    -- كل عنصر: { x, y, width, height } بالنسبة المئوية
    logo_position       jsonb not null default '{"x": 5, "y": 5, "width": 15, "height": 15}',
    stamp_position       jsonb not null default '{"x": 75, "y": 80, "width": 15, "height": 15}',
    signature_position   jsonb not null default '{"x": 40, "y": 80, "width": 20, "height": 10}',

    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

create index if not exists idx_document_templates_company on public.document_templates(company_id);

-- فهرس فريد جزئي: قالب واحد مفعّل فقط لكل منشأة في أي وقت
create unique index if not exists idx_one_active_template_per_company
    on public.document_templates(company_id)
    where is_active = true;

-- ============================================================
-- Row Level Security
-- ============================================================
alter table public.document_templates enable row level security;

drop policy if exists "select own document templates" on public.document_templates;
create policy "select own document templates"
    on public.document_templates for select
    using (auth.uid() = owner_id);

drop policy if exists "insert own document templates" on public.document_templates;
create policy "insert own document templates"
    on public.document_templates for insert
    with check (auth.uid() = owner_id);

drop policy if exists "update own document templates" on public.document_templates;
create policy "update own document templates"
    on public.document_templates for update
    using (auth.uid() = owner_id);

drop policy if exists "delete own document templates" on public.document_templates;
create policy "delete own document templates"
    on public.document_templates for delete
    using (auth.uid() = owner_id);

-- ############################################################
-- migration_salary_adjustments.sql
-- ############################################################
-- ============================================================
-- migration_salary_adjustments.sql
-- قسم "الرواتب" الجديد — سجل الزيادات/العلاوات/الإضافات الشهرية
-- ينفَّذ في Supabase SQL Editor مرة واحدة
-- ============================================================

create table if not exists public.salary_adjustments (
    id              uuid primary key default gen_random_uuid(),
    employee_id     uuid not null references public.employees(id) on delete cascade,
    owner_id        uuid not null references auth.users(id) on delete cascade,
    adjustment_type text not null check (adjustment_type in ('increase', 'allowance', 'bonus', 'deduction')),
    description     text not null default '',
    amount          numeric not null default 0,
    is_recurring    boolean not null default false,
    month           text not null,               -- بصيغة 'YYYY-MM'
    created_at      timestamptz not null default now()
);

-- فهرس لتسريع جلب تعديلات موظف معيّن، وآخر لتسريع الفلترة حسب الشهر
create index if not exists idx_salary_adjustments_employee on public.salary_adjustments(employee_id);
create index if not exists idx_salary_adjustments_month    on public.salary_adjustments(month);

-- ============================================================
-- Row Level Security: كل مستخدم يرى ويعدّل فقط تعديلات موظفيه
-- (نفس نمط الحماية المتوقع على بقية الجداول مثل custody_items)
-- ============================================================
alter table public.salary_adjustments enable row level security;

drop policy if exists "select own salary adjustments" on public.salary_adjustments;
create policy "select own salary adjustments"
    on public.salary_adjustments for select
    using (auth.uid() = owner_id);

drop policy if exists "insert own salary adjustments" on public.salary_adjustments;
create policy "insert own salary adjustments"
    on public.salary_adjustments for insert
    with check (auth.uid() = owner_id);

drop policy if exists "update own salary adjustments" on public.salary_adjustments;
create policy "update own salary adjustments"
    on public.salary_adjustments for update
    using (auth.uid() = owner_id);

drop policy if exists "delete own salary adjustments" on public.salary_adjustments;
create policy "delete own salary adjustments"
    on public.salary_adjustments for delete
    using (auth.uid() = owner_id);

-- ############################################################
-- migration_clearance_reason.sql
-- ############################################################
-- ============================================================
-- منصة الإلحاق — عمود سبب إنهاء الخدمة (اختياري)
-- يُستخدم بحاسبة مكافأة نهاية الخدمة ولوحة المتابعة وكشف المخالصة.
-- بدون هذا العمود تعمل الميزة وتحفظ السبب على المتصفح فقط.
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run
-- ============================================================
alter table public.employees
    add column if not exists clearance_reason text;

comment on column public.employees.clearance_reason is
    'مفتاح سبب إنهاء الخدمة: nonrenew_co | nonrenew_emp | art77 | art74 | resignation | probation_co | probation_emp';



-- ############################################################
-- migration_salary_structure.sql
-- ############################################################
-- ============================================================
-- منصة الإلحاق — البدلات الأخرى ضمن هيكل الراتب
-- الإجمالي = الأساسي + السكن (25% من الأساسي) + النقل (10% من الأساسي) + البدلات الأخرى
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run
-- ============================================================
alter table public.employees
    add column if not exists other_allowances numeric not null default 0;



-- ############################################################
-- migration_employee_gosi_emails.sql
-- ############################################################
-- ============================================================
-- منصة سعودي HR — الانتساب للتأمينات الاجتماعية + بريد المنشأة
-- (يتضمن أيضاً أعمدة المرحلة والمسار والاسم الإنجليزي إن لم تُنشأ سابقاً)
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run
-- ============================================================
alter table public.employees add column if not exists gosi_status text;   -- سعودي/أجنبي بالتأمينات أو خارجها
alter table public.employees add column if not exists work_email text;    -- بريد المنشأة (البريد الشخصي في العمود email)
alter table public.employees add column if not exists name_en text;
alter table public.employees add column if not exists school_stage text;
alter table public.employees add column if not exists track text;

-- تعبئة أولية للانتساب حسب الجنسية للموظفين الحاليين
update public.employees
   set gosi_status = case when nationality like 'سعود%' then 'سعودي بالتأمينات' else 'أجنبي بالتأمينات' end
 where gosi_status is null;



-- ############################################################
-- migration_hr_operations.sql
-- ############################################################
-- ============================================================
-- منصة الإلحاق — العمليات والحركات (جدول موحّد)
-- يغطي: إنهاء الخدمة (عمليات/تسوية/أنهي)، العمليات المالية (العلاوات،
-- الامتيازات خارج الراتب، الاقتطاعات الدائمة، حركات الضمان الاجتماعي،
-- الامتيازات السنوية، التأمين الصحي، التسديدات، الانقطاع عن العمل، نقل
-- الموظف، تعويضات الأداء، رسوم الخدمة)، التأمين الصحي (طلبات/متابعة)،
-- إصابات العمل ومصروفاتها، والمتابعات الشهرية (ملاحظات الشهر القادم).
--
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run (مرة واحدة)
-- ثم: Settings → Data API → أضف hr_operations إلى Exposed tables
-- ============================================================

create table if not exists public.hr_operations (
    id              uuid primary key default gen_random_uuid(),
    ref_no          bigint generated always as identity,
    company_id      uuid not null,
    owner_id        uuid not null default auth.uid(),
    employee_id     uuid references public.employees(id) on delete cascade,
    module          text not null,          -- termination | fin_allowance | ... | injury | followup
    sub_type        text,                   -- النوع داخل الوحدة (مثل: علاوة سنوية)
    status          text not null default 'open',
    amount          numeric,
    days            numeric,
    start_date      date,
    end_date        date,
    effective_month text,                   -- YYYY-MM: شهر السريان على الرواتب
    recurring       boolean not null default false,
    data            jsonb not null default '{}'::jsonb,
    notes           text,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

create index if not exists idx_hr_operations_company_module on public.hr_operations(company_id, module, status);
create index if not exists idx_hr_operations_employee on public.hr_operations(employee_id);

alter table public.hr_operations enable row level security;

drop policy if exists "owner manages hr operations" on public.hr_operations;
create policy "owner manages hr operations" on public.hr_operations
    for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());



-- ############################################################
-- migration_employee_self_service.sql
-- ############################################################
-- ============================================================
-- منصة الإلحاق — بوابة الخدمة الذاتية للموظف
-- الطلبات (إجازة، مغادرة، بدل إجازة، عمل إضافي، عمل من المنزل، مطالبة مالية، خطاب)
-- + سجل الحضور (تسجيل دخول/خروج) + دالة عرض بيانات الموظف الكاملة
--
-- تعمل البوابة بنفس رابط الموظف الحالي (portal_token + آخر 4 أرقام من الهوية).
-- تتفعّل الخدمة الذاتية الكاملة تلقائياً عند اكتمال الإلحاق (progress = 100)،
-- وقبل ذلك يرى الموظف صفحة رفع المستندات فقط.
--
-- التشغيل: Supabase Studio → SQL Editor → الصق الملف كاملاً ثم Run (مرة واحدة)
-- ثم: Settings → Data API → تأكد أن الجدولين والدوال الجديدة ضمن Exposed
-- ============================================================

-- ------------------------------------------------------------
-- 1) جدول الطلبات
-- ------------------------------------------------------------
create table if not exists public.employee_requests (
    id           uuid primary key default gen_random_uuid(),
    ref_no       bigint generated always as identity,
    employee_id  uuid not null references public.employees(id) on delete cascade,
    company_id   uuid,
    owner_id     uuid,
    request_type text not null check (request_type in
                   ('leave', 'permission', 'leave_allowance', 'overtime', 'wfh', 'financial_claim', 'letter', 'other')),
    sub_type     text,                    -- مثال: الإجازة السنوية / استئذان شخصي
    date_from    date,
    date_to      date,
    days         numeric,
    hours        numeric,
    amount       numeric,
    notes        text,
    status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
    hr_note      text,
    created_at   timestamptz not null default now(),
    decided_at   timestamptz
);
create index if not exists idx_employee_requests_company on public.employee_requests(company_id, status);
create index if not exists idx_employee_requests_employee on public.employee_requests(employee_id);

alter table public.employee_requests enable row level security;

drop policy if exists "owner manages requests" on public.employee_requests;
create policy "owner manages requests" on public.employee_requests
    for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ------------------------------------------------------------
-- 2) جدول الحضور (سجل واحد لكل موظف لكل يوم)
-- ------------------------------------------------------------
create table if not exists public.employee_attendance (
    id          uuid primary key default gen_random_uuid(),
    employee_id uuid not null references public.employees(id) on delete cascade,
    company_id  uuid,
    owner_id    uuid,
    work_date   date not null,
    check_in    timestamptz,
    check_out   timestamptz,
    source      text not null default 'portal',
    created_at  timestamptz not null default now(),
    unique (employee_id, work_date)
);
create index if not exists idx_employee_attendance_company on public.employee_attendance(company_id, work_date);

alter table public.employee_attendance enable row level security;

drop policy if exists "owner manages attendance" on public.employee_attendance;
create policy "owner manages attendance" on public.employee_attendance
    for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ------------------------------------------------------------
-- 3) دالة داخلية: التحقق من الرابط وآخر 4 أرقام
-- ------------------------------------------------------------
create or replace function public._portal_employee(p_token text, p_last4 text)
returns public.employees
language sql
security definer
set search_path = public
as $$
    select e.* from public.employees e
    where e.portal_token = p_token
      and e.portal_enabled = true
      and right(e.nid, 4) = p_last4
    limit 1;
$$;
revoke all on function public._portal_employee(text, text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- 4) بيانات الخدمة الذاتية كاملة
-- ------------------------------------------------------------
create or replace function public.portal_self_service(p_token text, p_last4 text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_emp   public.employees;
    v_comp  jsonb := '{}'::jsonb;
    v_dept  text;
    v_mgr   text;
    v_adj   jsonb := '[]'::jsonb;
    v_docs  jsonb := '[]'::jsonb;
    v_full  boolean;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then
        return jsonb_build_object('ok', false, 'error', 'invalid');
    end if;

    -- policy_settings تُقرأ بشكل مرن: تعود null إن لم يُضف العمود بعد
    select jsonb_build_object('name_ar', c.name_ar, 'policy_settings', public.portal_safe_settings(to_jsonb(c) -> 'policy_settings'))
    into v_comp from public.companies c where c.id = v_emp.company_id;

    begin select d.name into v_dept from public.departments d where d.id = v_emp.department_id;
    exception when others then v_dept := null; end;

    select m.name into v_mgr from public.employees m where m.id = v_emp.manager_id;

    begin
        select coalesce(jsonb_agg(to_jsonb(a) - 'owner_id' order by a.created_at desc), '[]'::jsonb) into v_adj
        from public.salary_adjustments a
        where a.employee_id = v_emp.id
          and (a.is_recurring or a.month >= to_char(now() - interval '6 months', 'YYYY-MM'));
    exception when undefined_table then v_adj := '[]'::jsonb; end;

    begin
        select coalesce(jsonb_agg(jsonb_build_object('doc_key', d.doc_key, 'file_name', d.file_name, 'uploaded_at', d.uploaded_at)), '[]'::jsonb)
        into v_docs from public.employee_documents d where d.employee_id = v_emp.id;
    exception when undefined_table then v_docs := '[]'::jsonb; end;

    v_full := coalesce(v_emp.progress, 0) >= 100
              and coalesce(v_emp.is_terminated, false) = false;

    return jsonb_build_object(
        'ok', true,
        'full_access', v_full,
        'employee', (to_jsonb(v_emp) - 'owner_id' - 'portal_token' - 'clearance_tasks' - 'completed_tasks')
                    || jsonb_build_object('department_name', v_dept, 'manager_name', v_mgr),
        'company', v_comp,
        'adjustments', v_adj,
        'documents', v_docs,
        'requests', coalesce((
            select jsonb_agg(to_jsonb(r) - 'owner_id' order by r.created_at desc)
            from public.employee_requests r where r.employee_id = v_emp.id
        ), '[]'::jsonb),
        'attendance', coalesce((
            select jsonb_agg(to_jsonb(t) - 'owner_id' order by t.work_date desc)
            from public.employee_attendance t
            where t.employee_id = v_emp.id and t.work_date >= (now() at time zone 'Asia/Riyadh')::date - 62
        ), '[]'::jsonb),
        'today', (now() at time zone 'Asia/Riyadh')::date
    );
end;
$$;

-- ------------------------------------------------------------
-- 5) تقديم طلب
-- ------------------------------------------------------------
create or replace function public.portal_submit_request(
    p_token text, p_last4 text, p_type text, p_sub_type text,
    p_from date, p_to date, p_days numeric, p_hours numeric, p_amount numeric, p_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_emp public.employees; v_id uuid;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    if coalesce(v_emp.progress, 0) < 100 then
        return jsonb_build_object('ok', false, 'error', 'not_enabled');
    end if;
    insert into public.employee_requests
        (employee_id, company_id, owner_id, request_type, sub_type, date_from, date_to, days, hours, amount, notes)
    values
        (v_emp.id, v_emp.company_id, v_emp.owner_id, p_type, nullif(p_sub_type, ''), p_from, p_to, p_days, p_hours, p_amount, left(coalesce(p_notes, ''), 1000))
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ------------------------------------------------------------
-- 6) إلغاء طلب ما زال قيد الانتظار
-- ------------------------------------------------------------
create or replace function public.portal_cancel_request(p_token text, p_last4 text, p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_emp public.employees;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    update public.employee_requests set status = 'cancelled', decided_at = now()
    where id = p_request_id and employee_id = v_emp.id and status = 'pending';
    return jsonb_build_object('ok', found);
end;
$$;

-- ------------------------------------------------------------
-- 7) تسجيل الحضور والانصراف (بتوقيت الرياض)
-- ------------------------------------------------------------
create or replace function public.portal_punch(p_token text, p_last4 text, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_emp public.employees; v_day date := (now() at time zone 'Asia/Riyadh')::date;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    if coalesce(v_emp.progress, 0) < 100 then return jsonb_build_object('ok', false, 'error', 'not_enabled'); end if;

    if p_action = 'in' then
        insert into public.employee_attendance (employee_id, company_id, owner_id, work_date, check_in)
        values (v_emp.id, v_emp.company_id, v_emp.owner_id, v_day, now())
        on conflict (employee_id, work_date) do nothing;
    elsif p_action = 'out' then
        update public.employee_attendance set check_out = now()
        where employee_id = v_emp.id and work_date = v_day and check_in is not null;
        if not found then return jsonb_build_object('ok', false, 'error', 'no_check_in'); end if;
    else
        return jsonb_build_object('ok', false, 'error', 'bad_action');
    end if;
    return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.portal_self_service(text, text) to anon, authenticated;
grant execute on function public.portal_submit_request(text, text, text, text, date, date, numeric, numeric, numeric, text) to anon, authenticated;
grant execute on function public.portal_cancel_request(text, text, uuid) to anon, authenticated;
grant execute on function public.portal_punch(text, text, text) to anon, authenticated;



-- ############################################################
-- migration_policy_settings.sql
-- ############################################################
-- ============================================================
-- منصة الإلحاق — حفظ إعدادات "السياسات والجداول" لكل منشأة
-- يحفظ تبديلات (نعم/لا، نشط/غير نشط) بقاعدة البيانات بدل المتصفح فقط،
-- ويجعلها تنعكس على بوابة الخدمة الذاتية للموظفين.
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run (بعد migration_employee_self_service.sql)
-- ============================================================
alter table public.companies
    add column if not exists policy_settings jsonb not null default '{}'::jsonb;

comment on column public.companies.policy_settings is
    'فروقات إعدادات السياسات عن القيم الافتراضية: {gosi:{saudi:{exempt:true}}, leavesPaid:{"الإجازة السنوية":{selfService:false}}, ...}';

-- ------------------------------------------------------------
-- 4) بيانات الخدمة الذاتية كاملة
-- ------------------------------------------------------------
create or replace function public.portal_self_service(p_token text, p_last4 text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_emp   public.employees;
    v_comp  jsonb := '{}'::jsonb;
    v_dept  text;
    v_mgr   text;
    v_adj   jsonb := '[]'::jsonb;
    v_docs  jsonb := '[]'::jsonb;
    v_full  boolean;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then
        return jsonb_build_object('ok', false, 'error', 'invalid');
    end if;

    -- policy_settings تُقرأ بشكل مرن: تعود null إن لم يُضف العمود بعد
    select jsonb_build_object('name_ar', c.name_ar, 'policy_settings', public.portal_safe_settings(to_jsonb(c) -> 'policy_settings'))
    into v_comp from public.companies c where c.id = v_emp.company_id;

    begin select d.name into v_dept from public.departments d where d.id = v_emp.department_id;
    exception when others then v_dept := null; end;

    select m.name into v_mgr from public.employees m where m.id = v_emp.manager_id;

    begin
        select coalesce(jsonb_agg(to_jsonb(a) - 'owner_id' order by a.created_at desc), '[]'::jsonb) into v_adj
        from public.salary_adjustments a
        where a.employee_id = v_emp.id
          and (a.is_recurring or a.month >= to_char(now() - interval '6 months', 'YYYY-MM'));
    exception when undefined_table then v_adj := '[]'::jsonb; end;

    begin
        select coalesce(jsonb_agg(jsonb_build_object('doc_key', d.doc_key, 'file_name', d.file_name, 'uploaded_at', d.uploaded_at)), '[]'::jsonb)
        into v_docs from public.employee_documents d where d.employee_id = v_emp.id;
    exception when undefined_table then v_docs := '[]'::jsonb; end;

    v_full := coalesce(v_emp.progress, 0) >= 100
              and coalesce(v_emp.is_terminated, false) = false;

    return jsonb_build_object(
        'ok', true,
        'full_access', v_full,
        'employee', (to_jsonb(v_emp) - 'owner_id' - 'portal_token' - 'clearance_tasks' - 'completed_tasks')
                    || jsonb_build_object('department_name', v_dept, 'manager_name', v_mgr),
        'company', v_comp,
        'adjustments', v_adj,
        'documents', v_docs,
        'requests', coalesce((
            select jsonb_agg(to_jsonb(r) - 'owner_id' order by r.created_at desc)
            from public.employee_requests r where r.employee_id = v_emp.id
        ), '[]'::jsonb),
        'attendance', coalesce((
            select jsonb_agg(to_jsonb(t) - 'owner_id' order by t.work_date desc)
            from public.employee_attendance t
            where t.employee_id = v_emp.id and t.work_date >= (now() at time zone 'Asia/Riyadh')::date - 62
        ), '[]'::jsonb),
        'today', (now() at time zone 'Asia/Riyadh')::date
    );
end;
$$;



-- ############################################################
-- migration_hr_documents_storage.sql
-- ############################################################
-- ============================================================
-- منصة سعودي HR — مخزن خاص للنماذج المرسلة للموظفين (روابط موقّتة 7 أيام)
-- مخزن خاص (غير عام): لا يُفتح الملف إلا برابط موقّع ينتهي تلقائياً
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run
-- ============================================================
insert into storage.buckets (id, name, public)
values ('hr-documents', 'hr-documents', false)
on conflict (id) do nothing;

-- كل مستخدم يرفع ويقرأ داخل مجلده فقط: hr-documents/<user_id>/...
drop policy if exists "hr docs owner insert" on storage.objects;
create policy "hr docs owner insert" on storage.objects for insert to authenticated
    with check (bucket_id = 'hr-documents' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "hr docs owner select" on storage.objects;
create policy "hr docs owner select" on storage.objects for select to authenticated
    using (bucket_id = 'hr-documents' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "hr docs owner delete" on storage.objects;
create policy "hr docs owner delete" on storage.objects for delete to authenticated
    using (bucket_id = 'hr-documents' and (storage.foldername(name))[1] = auth.uid()::text);

-- ############################################################
-- طريقة صرف الراتب (حماية الأجور / غير حماية / كاش) + تاريخ آخر تعديل
-- ############################################################
alter table public.employees add column if not exists pay_method text;   -- wps | bank | cash
update public.employees
   set pay_method = case when iban ~ '^SA[0-9]{22}$' then 'wps' else 'cash' end
 where pay_method is null;


-- ############################################################
-- migration_portal_profile_offer.sql
-- ############################################################
-- ============================================================
-- منصة سعودي HR — رابط الموظف: تعبئة بياناته بنفسه + توقيع العرض الوظيفي إلكترونياً
-- + حقول إضافية (الجواز، الزائر، إيضاح طريقة الصرف)
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run (بعد supabase_all_in_one.sql)
-- ============================================================
alter table public.employees add column if not exists passport_no text;
alter table public.employees add column if not exists passport_issue_date date;
alter table public.employees add column if not exists passport_expiry date;
alter table public.employees add column if not exists passport_issue_place text;
alter table public.employees add column if not exists is_visitor boolean not null default false;
alter table public.employees add column if not exists visitor_note text;
alter table public.employees add column if not exists pay_method_note text;
alter table public.employees add column if not exists pay_method text;
alter table public.employees add column if not exists offer_status text;          -- sent | accepted | declined
alter table public.employees add column if not exists offer_signature text;       -- صورة التوقيع (data URL)
alter table public.employees add column if not exists offer_signed_at timestamptz;
alter table public.employees add column if not exists profile_submitted_at timestamptz;

-- ------------------------------------------------------------
-- الموظف يُحدّث بياناته من الرابط (حقول محددة فقط — لا يمكنه تعديل الراتب أو المسار)
-- ------------------------------------------------------------
create or replace function public.portal_update_profile(p_token text, p_last4 text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_emp public.employees;
    v    text;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;

    update public.employees set
        name_en              = coalesce(nullif(trim(p_data->>'name_en'), ''), name_en),
        gender               = coalesce(nullif(trim(p_data->>'gender'), ''), gender),
        marital_status       = coalesce(nullif(trim(p_data->>'marital_status'), ''), marital_status),
        religion             = coalesce(nullif(trim(p_data->>'religion'), ''), religion),
        phone                = coalesce(nullif(trim(p_data->>'phone'), ''), phone),
        email                = coalesce(nullif(trim(p_data->>'email'), ''), email),
        education            = coalesce(nullif(trim(p_data->>'education'), ''), education),
        specialty            = coalesce(nullif(trim(p_data->>'specialty'), ''), specialty),
        bank                 = coalesce(nullif(trim(p_data->>'bank'), ''), bank),
        iban                 = coalesce(nullif(upper(replace(p_data->>'iban', ' ', '')), ''), iban),
        current_address      = coalesce(nullif(trim(p_data->>'current_address'), ''), current_address),
        passport_no          = coalesce(nullif(trim(p_data->>'passport_no'), ''), passport_no),
        passport_issue_place = coalesce(nullif(trim(p_data->>'passport_issue_place'), ''), passport_issue_place),
        passport_issue_date  = coalesce(nullif(p_data->>'passport_issue_date', '')::date, passport_issue_date),
        passport_expiry      = coalesce(nullif(p_data->>'passport_expiry', '')::date, passport_expiry),
        profile_submitted_at = now()
    where id = v_emp.id;
    -- تاريخا الميلاد وانتهاء الهوية: قيمة حرفية تُحوَّل تلقائياً لنوع العمود (نص أو تاريخ)
    v := nullif(trim(p_data->>'dob'), '');
    if v is not null then execute format('update public.employees set dob = %L where id = %L', v, v_emp.id); end if;
    v := nullif(trim(p_data->>'id_expiry'), '');
    if v is not null then execute format('update public.employees set id_expiry = %L where id = %L', v, v_emp.id); end if;
    return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- توقيع العرض الوظيفي من الرابط (قبول أو اعتذار) مع صورة التوقيع
-- ------------------------------------------------------------
create or replace function public.portal_sign_offer(p_token text, p_last4 text, p_signature text, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_emp public.employees;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    if p_accept and coalesce(length(p_signature), 0) < 200 then return jsonb_build_object('ok', false, 'error', 'signature_required'); end if;
    -- صورة توقيع حقيقية فقط (يمنع حقن نص يُعرض لاحقاً في لوحة الإدارة)
    if p_accept and p_signature !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$' then return jsonb_build_object('ok', false, 'error', 'invalid_signature'); end if;
    if length(coalesce(p_signature, '')) > 400000 then return jsonb_build_object('ok', false, 'error', 'signature_too_large'); end if;
    update public.employees
       set offer_status = case when p_accept then 'accepted' else 'declined' end,
           offer_signature = case when p_accept then p_signature else null end,
           offer_signed_at = now()
     where id = v_emp.id;
    return jsonb_build_object('ok', true, 'status', case when p_accept then 'accepted' else 'declined' end);
end;
$$;

grant execute on function public.portal_update_profile(text, text, jsonb) to anon, authenticated;
grant execute on function public.portal_sign_offer(text, text, text, boolean) to anon, authenticated;

notify pgrst, 'reload schema';

-- ############################################################
-- migration_tenant_isolation.sql
-- ############################################################
-- ============================================================
-- منصة سعودي HR — عزل بيانات كل حساب (Tenant Isolation)
-- السبب: سياسات قراءة عامة على جدول المنشآت/الموظفين تجعل مستخدماً يرى منشآت
-- مستخدم آخر (مثلاً سياسة أُضيفت ليعمل فحص تكرار البريد عند التسجيل)،
-- فيختار منشأة غيره ويُضيف فيها موظفين.
-- الحل: حذف كل السياسات القديمة على جداول البيانات، وإعادة إنشائها بحيث
-- لا يرى ولا يعدّل أي مستخدم إلا منشآته هو وما يتبعها.
--
-- التشغيل: Supabase Studio → SQL Editor → نفّذ القسم (0) أولاً للتشخيص،
-- ثم الملف كاملاً. (آمن لإعادة التشغيل)
-- ============================================================

-- ------------------------------------------------------------
-- (0) تشخيص — نفّذ هذه الاستعلامات وحدها لرؤية المشكلة قبل الإصلاح:
-- ------------------------------------------------------------
-- أ) السياسات الحالية على الجداول:
--   select tablename, policyname, cmd, roles, qual from pg_policies
--    where schemaname = 'public' and tablename in ('companies','employees','departments') order by 1,2;
-- ب) موظفون أُضيفوا بحساب مختلف عن مالك منشأتهم (سبب ظهورهم عند الحساب الآخر):
--   select e.name, e.company_id, c.name_ar as company, ue.email as added_by, uc.email as company_owner
--     from public.employees e join public.companies c on c.id = e.company_id
--     left join auth.users ue on ue.id = e.owner_id left join auth.users uc on uc.id = c.owner_id
--    where e.owner_id is distinct from c.owner_id;

-- ------------------------------------------------------------
-- (1) دوال مساعدة: هل المنشأة/الموظف ملك المستخدم الحالي؟
-- ------------------------------------------------------------
create or replace function public.owns_company(p_company uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.companies c where c.id = p_company and c.owner_id = auth.uid());
$$;
create or replace function public.owns_employee(p_employee uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.employees e join public.companies c on c.id = e.company_id
                    where e.id = p_employee and c.owner_id = auth.uid());
$$;
grant execute on function public.owns_company(uuid) to authenticated;
grant execute on function public.owns_employee(uuid) to authenticated;

-- ------------------------------------------------------------
-- (2) تصحيح البيانات المتداخلة: موظف أضافه حساب داخل منشأة حساب آخر
--     يُعاد إلى منشأة من أضافه (إن كان يملك منشأة واحدة فقط)، مع سجلاته التابعة.
--     من يملك أكثر من منشأة يبقى للمراجعة اليدوية (يظهر في الاستعلام (0-ب)).
-- ------------------------------------------------------------
do $$
declare r record; v_target uuid;
begin
    for r in
        select e.id, e.owner_id from public.employees e join public.companies c on c.id = e.company_id
         where e.owner_id is not null and e.owner_id is distinct from c.owner_id
    loop
        select case when count(*) = 1 then min(id::text)::uuid end into v_target
          from public.companies where owner_id = r.owner_id;
        if v_target is not null then
            update public.employees set company_id = v_target where id = r.id;
            if to_regclass('public.hr_operations') is not null then update public.hr_operations set company_id = v_target where employee_id = r.id; end if;
            if to_regclass('public.employee_requests') is not null then update public.employee_requests set company_id = v_target where employee_id = r.id; end if;
            if to_regclass('public.employee_attendance') is not null then update public.employee_attendance set company_id = v_target where employee_id = r.id; end if;
        end if;
    end loop;
end $$;

-- ------------------------------------------------------------
-- (3) حذف كل السياسات القديمة (بما فيها أي سياسة قراءة عامة) وإعادة بنائها بصرامة
-- ------------------------------------------------------------
do $$
declare r record;
begin
    for r in select tablename, policyname from pg_policies
              where schemaname = 'public' and tablename in ('companies','employees','departments','document_templates','hr_operations',
                    'employee_requests','employee_attendance','salary_adjustments','custody_items','employee_documents')
    loop
        execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
    end loop;
end $$;

-- المنشآت: المالك فقط
alter table public.companies enable row level security;
create policy "tenant companies select" on public.companies for select to authenticated using (owner_id = auth.uid());
create policy "tenant companies insert" on public.companies for insert to authenticated with check (owner_id = auth.uid());
create policy "tenant companies update" on public.companies for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "tenant companies delete" on public.companies for delete to authenticated using (owner_id = auth.uid());

-- الجداول المرتبطة بالمنشأة مباشرة (company_id)
do $$
declare t text;
begin
    foreach t in array array['employees','departments','document_templates','hr_operations','employee_requests','employee_attendance'] loop
        if to_regclass('public.' || t) is null then continue; end if;
        execute format('alter table public.%I enable row level security', t);
        -- جدول بلا عمود company_id: يُقيَّد بمالك السجل
        if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'company_id') then
            execute format('create policy %I on public.%I for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid())', 'tenant ' || t || ' owner', t);
            continue;
        end if;
        execute format('create policy %I on public.%I for select to authenticated using (public.owns_company(company_id))', 'tenant ' || t || ' select', t);
        execute format('create policy %I on public.%I for insert to authenticated with check (public.owns_company(company_id))', 'tenant ' || t || ' insert', t);
        execute format('create policy %I on public.%I for update to authenticated using (public.owns_company(company_id)) with check (public.owns_company(company_id))', 'tenant ' || t || ' update', t);
        execute format('create policy %I on public.%I for delete to authenticated using (public.owns_company(company_id))', 'tenant ' || t || ' delete', t);
    end loop;
end $$;

-- الجداول المرتبطة بالموظف (employee_id)
do $$
declare t text;
begin
    foreach t in array array['salary_adjustments','custody_items','employee_documents'] loop
        if to_regclass('public.' || t) is null then continue; end if;
        execute format('alter table public.%I enable row level security', t);
        execute format('create policy %I on public.%I for all to authenticated using (public.owns_employee(employee_id)) with check (public.owns_employee(employee_id))', 'tenant ' || t || ' all', t);
    end loop;
end $$;

-- ------------------------------------------------------------
-- (4) فحص تكرار بيانات التسجيل دون فتح جدول المنشآت للعامة
-- ------------------------------------------------------------
create or replace function public.registration_conflicts(p_email text, p_mobile text, p_unified text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
    select jsonb_build_object(
        'email',   exists (select 1 from public.companies where lower(contact_email) = lower(p_email)),
        'mobile',  exists (select 1 from public.companies where mobile = p_mobile),
        'unified', exists (select 1 from public.companies where unified_number = p_unified)) into v;
    return v;
exception when undefined_column then
    return jsonb_build_object('email', false, 'mobile', false, 'unified', false, 'missing_columns', true);
end;
$$;
grant execute on function public.registration_conflicts(text, text, text) to anon, authenticated;

-- ملاحظة: دوال بوابة الموظف (portal_*) تعمل بصلاحية SECURITY DEFINER فلا تتأثر بهذه السياسات،
-- وسياسات التخزين (storage.objects) لم تُغيَّر.
notify pgrst, 'reload schema';

-- ############################################################
-- migration_geofence_attendance.sql
-- ############################################################
-- ============================================================
-- منصة سعودي HR — البصمة ضمن نطاق مقر المنشأة (Geofence)
-- يُحفظ مقر المنشأة ونطاقه في إعدادات المنشأة (policy_settings -> geo)
-- ويتحقق الخادم من موقع الموظف قبل قبول الحضور أو الانصراف (لا يكفي التحقق في المتصفح)
-- التشغيل: Supabase Studio → SQL Editor → الصق ثم Run
-- ============================================================
alter table public.employee_attendance add column if not exists check_in_lat double precision;
alter table public.employee_attendance add column if not exists check_in_lng double precision;
alter table public.employee_attendance add column if not exists check_out_lat double precision;
alter table public.employee_attendance add column if not exists check_out_lng double precision;
alter table public.employee_attendance add column if not exists distance_m integer;

-- المسافة بالمتر بين نقطتين (Haversine)
create or replace function public.geo_distance_m(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
    select 2 * 6371000 * asin(sqrt(power(sin(radians(lat2 - lat1) / 2), 2) + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)));
$$;

create or replace function public.portal_punch_geo(p_token text, p_last4 text, p_action text, p_lat double precision, p_lng double precision, p_accuracy double precision)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_emp public.employees; v_day date := (now() at time zone 'Asia/Riyadh')::date;
    v_geo jsonb; v_dist double precision; v_radius double precision;
begin
    v_emp := public._portal_employee(p_token, p_last4);
    if v_emp.id is null then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
    if coalesce(v_emp.progress, 0) < 100 then return jsonb_build_object('ok', false, 'error', 'not_enabled'); end if;

    select c.policy_settings -> 'geo' into v_geo from public.companies c where c.id = v_emp.company_id;
    if coalesce((v_geo ->> 'enabled')::boolean, false) then
        if p_lat is null or p_lng is null then return jsonb_build_object('ok', false, 'error', 'location_required'); end if;
        v_radius := coalesce((v_geo ->> 'radius')::double precision, 150);
        v_dist := public.geo_distance_m((v_geo ->> 'lat')::double precision, (v_geo ->> 'lng')::double precision, p_lat, p_lng);
        -- هامش يسير لدقة GPS (حتى 50م) دون السماح بالتسجيل من مكان بعيد
        if v_dist - least(coalesce(p_accuracy, 0), 50) > v_radius then
            return jsonb_build_object('ok', false, 'error', 'outside_area', 'distance', round(v_dist), 'radius', v_radius);
        end if;
    end if;

    if p_action = 'in' then
        insert into public.employee_attendance (employee_id, company_id, owner_id, work_date, check_in, check_in_lat, check_in_lng, distance_m)
        values (v_emp.id, v_emp.company_id, v_emp.owner_id, v_day, now(), p_lat, p_lng, round(v_dist))
        on conflict (employee_id, work_date) do nothing;
    elsif p_action = 'out' then
        update public.employee_attendance set check_out = now(), check_out_lat = p_lat, check_out_lng = p_lng
        where employee_id = v_emp.id and work_date = v_day and check_in is not null;
        if not found then return jsonb_build_object('ok', false, 'error', 'no_check_in'); end if;
    else
        return jsonb_build_object('ok', false, 'error', 'bad_action');
    end if;
    return jsonb_build_object('ok', true, 'distance', round(v_dist));
end;
$$;

-- الدالة القديمة تمر بالتحقق نفسه (فلا يمكن تجاوز النطاق باستدعائها مباشرة)
create or replace function public.portal_punch(p_token text, p_last4 text, p_action text)
returns jsonb language sql security definer set search_path = public as $$
    select public.portal_punch_geo(p_token, p_last4, p_action, null, null, null);
$$;

grant execute on function public.portal_punch_geo(text, text, text, double precision, double precision, double precision) to anon, authenticated;
grant execute on function public.portal_punch(text, text, text) to anon, authenticated;
notify pgrst, 'reload schema';

-- ############################################################
-- migration_users_idcards.sql
-- ############################################################
-- ============================================================
-- منصة سعودي HR — إدارة المستخدمين (فريق المنشأة) + حقول بطاقة التعريف
-- الأدوار: admin (مدير كامل + إدارة المستخدمين) | hr (موارد بشرية) | accountant (محاسب) | viewer (مشاهدة فقط)
-- يُشغَّل بعد migration_tenant_isolation.sql — آمن لإعادة التشغيل
-- ============================================================
create table if not exists public.company_members (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null references public.companies(id) on delete cascade,
    email       text not null,
    user_id     uuid,
    role        text not null default 'hr' check (role in ('admin', 'hr', 'accountant', 'viewer')),
    invited_by  uuid default auth.uid(),
    created_at  timestamptz not null default now(),
    joined_at   timestamptz,
    unique (company_id, email)
);
create index if not exists idx_company_members_user on public.company_members(user_id);

-- حقول بطاقة التعريف والعنوان الحالي
alter table public.employees add column if not exists photo text;            -- صورة مصغّرة (data URL)
alter table public.employees add column if not exists current_address text;

-- ------------------------------------------------------------
-- دوال الصلاحيات
-- ------------------------------------------------------------
create or replace function public.member_role(p_company uuid)
returns text language sql stable security definer set search_path = public as $$
    select case when exists (select 1 from public.companies c where c.id = p_company and c.owner_id = auth.uid()) then 'owner'
                else (select m.role from public.company_members m where m.company_id = p_company and m.user_id = auth.uid() limit 1) end;
$$;
-- قراءة: المالك أو أي عضو
create or replace function public.owns_company(p_company uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select public.member_role(p_company) is not null;
$$;
-- كتابة البيانات: المالك والمدير والموارد البشرية والمحاسب
create or replace function public.can_write_company(p_company uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select coalesce(public.member_role(p_company) in ('owner', 'admin', 'hr', 'accountant'), false);
$$;
-- إدارة المستخدمين وإعدادات المنشأة الحساسة: المالك والمدير
create or replace function public.can_admin_company(p_company uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select coalesce(public.member_role(p_company) in ('owner', 'admin'), false);
$$;
create or replace function public.owns_employee(p_employee uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.employees e where e.id = p_employee and public.owns_company(e.company_id));
$$;
create or replace function public.can_write_employee(p_employee uuid)
returns boolean language sql stable security definer set search_path = public as $$
    select exists (select 1 from public.employees e where e.id = p_employee and public.can_write_company(e.company_id));
$$;
-- منشآت المستخدم (يملكها أو عضو فيها)
create or replace function public.my_company_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
    select id from public.companies where owner_id = auth.uid()
    union select company_id from public.company_members where user_id = auth.uid();
$$;
-- قبول الدعوات تلقائياً عند الدخول بنفس البريد المدعو
create or replace function public.accept_company_invites()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
    update public.company_members set user_id = auth.uid(), joined_at = now()
     where user_id is null and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''));
    get diagnostics n = row_count; return n;
end; $$;
grant execute on function public.member_role(uuid), public.can_write_company(uuid), public.can_admin_company(uuid),
    public.can_write_employee(uuid), public.my_company_ids(), public.accept_company_invites() to authenticated;

-- ------------------------------------------------------------
-- إعادة بناء سياسات الجداول بالأدوار
-- ------------------------------------------------------------
do $$
declare r record;
begin
    for r in select tablename, policyname from pg_policies where schemaname = 'public'
              and tablename in ('companies','employees','departments','document_templates','hr_operations','employee_requests','employee_attendance',
                                'salary_adjustments','custody_items','employee_documents','company_members')
    loop execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

alter table public.companies enable row level security;
create policy "co select" on public.companies for select to authenticated using (public.owns_company(id));
create policy "co insert" on public.companies for insert to authenticated with check (owner_id = auth.uid());
create policy "co update" on public.companies for update to authenticated using (public.member_role(id) in ('owner', 'admin', 'hr')) with check (public.member_role(id) in ('owner', 'admin', 'hr'));
create policy "co delete" on public.companies for delete to authenticated using (owner_id = auth.uid());

do $$
declare t text;
begin
    foreach t in array array['employees','departments','document_templates','hr_operations','employee_requests','employee_attendance'] loop
        if to_regclass('public.' || t) is null then continue; end if;
        execute format('alter table public.%I enable row level security', t);
        if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'company_id') then
            execute format('create policy %I on public.%I for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid())', 'r ' || t || ' owner', t);
            continue;
        end if;
        execute format('create policy %I on public.%I for select to authenticated using (public.owns_company(company_id))', 'r ' || t || ' select', t);
        execute format('create policy %I on public.%I for insert to authenticated with check (public.can_write_company(company_id))', 'r ' || t || ' insert', t);
        execute format('create policy %I on public.%I for update to authenticated using (public.can_write_company(company_id)) with check (public.can_write_company(company_id))', 'r ' || t || ' update', t);
        execute format('create policy %I on public.%I for delete to authenticated using (public.can_write_company(company_id))', 'r ' || t || ' delete', t);
    end loop;
    foreach t in array array['salary_adjustments','custody_items','employee_documents'] loop
        if to_regclass('public.' || t) is null then continue; end if;
        execute format('alter table public.%I enable row level security', t);
        execute format('create policy %I on public.%I for select to authenticated using (public.owns_employee(employee_id))', 'r ' || t || ' select', t);
        execute format('create policy %I on public.%I for all to authenticated using (public.can_write_employee(employee_id)) with check (public.can_write_employee(employee_id))', 'r ' || t || ' write', t);
    end loop;
end $$;

alter table public.company_members enable row level security;
create policy "members select" on public.company_members for select to authenticated using (public.owns_company(company_id) or user_id = auth.uid());
create policy "members manage" on public.company_members for all to authenticated using (public.can_admin_company(company_id)) with check (public.can_admin_company(company_id));

notify pgrst, 'reload schema';

-- ############################################################
-- migration_ask_knowledge.sql
-- ############################################################
-- ============================================================
-- منصة سعودي HR — مراجع المساعد الذكي "اسألني"
-- ملفات (لائحة داخلية، دليل موظف، سياسات) تُقسَّم لمقاطع وتُحفظ لكل منشأة،
-- ويستشيرها المساعد قبل الإجابة (تُقرأ من الخادم فقط عبر دالة ask-hr).
-- التشغيل: Supabase Studio → SQL Editor (بعد migration_users_idcards.sql) — آمن لإعادة التشغيل
-- ============================================================
create table if not exists public.ask_knowledge (
    id          uuid primary key default gen_random_uuid(),
    company_id  uuid not null references public.companies(id) on delete cascade,
    doc_id      uuid not null,
    doc_name    text not null,
    chunk_index integer not null default 0,
    content     text not null,
    created_by  uuid default auth.uid(),
    created_at  timestamptz not null default now()
);
create index if not exists idx_ask_knowledge_company on public.ask_knowledge(company_id, doc_id);

alter table public.ask_knowledge enable row level security;
do $$
declare r record; v_write text;
begin
    for r in select policyname from pg_policies where schemaname = 'public' and tablename = 'ask_knowledge'
    loop execute format('drop policy if exists %I on public.ask_knowledge', r.policyname); end loop;

    -- الكتابة: من لهم صلاحية كتابة على المنشأة (المالك/المدير/الموارد البشرية/المحاسب) إن وُجدت الأدوار، وإلا المالك
    v_write := case when to_regprocedure('public.can_write_company(uuid)') is not null then 'public.can_write_company(company_id)' else 'public.owns_company(company_id)' end;
    execute 'create policy "ask_kb select" on public.ask_knowledge for select to authenticated using (public.owns_company(company_id))';
    execute format('create policy "ask_kb insert" on public.ask_knowledge for insert to authenticated with check (%s)', v_write);
    execute format('create policy "ask_kb delete" on public.ask_knowledge for delete to authenticated using (%s)', v_write);
end $$;

notify pgrst, 'reload schema';
