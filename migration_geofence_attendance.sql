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
