create or replace function public.create_shipment_atomic(
    p_organization_id uuid,
    p_client_name text,
    p_mode text,
    p_route text,
    p_incoterm text,
    p_cargo text,
    p_eta date,
    p_income numeric,
    p_vehicle_data jsonb
)
returns table (
    id uuid,
    customer_id uuid,
    client_name text,
    code text,
    mode text,
    route text,
    incoterm text,
    cargo text,
    status text,
    eta date,
    created_at timestamptz
)
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_customer_id uuid;
    v_shipment public.shipments%rowtype;
    v_client_name text := btrim(coalesce(p_client_name, ''));
    v_route text := btrim(coalesce(p_route, ''));
    v_mode_prefix text;
    v_vehicle_data jsonb := coalesce(p_vehicle_data, '{}'::jsonb);
begin
    if (select auth.uid()) is null then
        raise exception 'Giriş yapmanız gerekiyor.' using errcode = '28000';
    end if;

    if not (select private.has_org_role(
        p_organization_id,
        array['owner', 'admin', 'operations']::text[]
    )) then
        raise exception 'Bu işlem için yetkiniz yok.' using errcode = '42501';
    end if;

    if v_client_name = '' or v_route = '' then
        raise exception 'Müşteri adı ve güzergah gereklidir.' using errcode = '22023';
    end if;

    if coalesce(p_mode, '') not in ('Karayolu', 'Denizyolu', 'Havayolu', 'Demiryolu') then
        raise exception 'Geçersiz taşıma türü.' using errcode = '22023';
    end if;

    if p_income is null or p_income <= 0 or p_income::text in ('NaN', 'Infinity', '-Infinity') then
        raise exception 'Navlun geliri sıfırdan büyük olmalıdır.' using errcode = '22023';
    end if;

    if jsonb_typeof(v_vehicle_data) <> 'object' then
        raise exception 'Araç bilgileri geçersiz.' using errcode = '22023';
    end if;

    select customer.id
      into v_customer_id
      from public.customers as customer
     where customer.organization_id = p_organization_id
       and lower(btrim(customer.name)) = lower(v_client_name)
     order by customer.created_at asc, customer.id asc
     limit 1;

    if v_customer_id is null then
        insert into public.customers (organization_id, name)
        values (p_organization_id, v_client_name)
        returning id into v_customer_id;
    end if;

    v_mode_prefix := case p_mode
        when 'Denizyolu' then 'SEA-'
        when 'Havayolu' then 'AIR-'
        when 'Demiryolu' then 'RAIL-'
        else 'TR-'
    end;

    insert into public.shipments (
        organization_id, customer_id, created_by, code, mode, route, incoterm, cargo, status, eta,
        documents, document_applicability, history, updated_at
    )
    values (
        p_organization_id, v_customer_id, (select auth.uid()),
        v_mode_prefix || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
        p_mode, v_route, coalesce(p_incoterm, ''), coalesce(p_cargo, ''),
        'Yükleme Bekliyor', p_eta, '{}'::jsonb, '{}'::jsonb, '[]'::jsonb, now()
    )
    returning * into v_shipment;

    insert into public.shipment_private (shipment_id, organization_id, internal_data)
    values (
        v_shipment.id,
        p_organization_id,
        jsonb_build_object(
            'income', p_income, 'expense1', 0, 'expense2', 0,
            'plate', coalesce(v_vehicle_data->>'plate', ''),
            'driver', coalesce(v_vehicle_data->>'driver', ''),
            'phone', coalesce(v_vehicle_data->>'phone', ''),
            'vessel', coalesce(v_vehicle_data->>'vessel', ''),
            'containerNo', coalesce(v_vehicle_data->>'containerNo', ''),
            'containerType', coalesce(v_vehicle_data->>'containerType', ''),
            'blNumber', coalesce(v_vehicle_data->>'blNumber', ''),
            'flightNo', coalesce(v_vehicle_data->>'flightNo', ''),
            'awbNumber', coalesce(v_vehicle_data->>'awbNumber', ''),
            'volWeight', coalesce(v_vehicle_data->>'volWeight', '')
        )
    );

    return query
    select v_shipment.id, v_shipment.customer_id, v_client_name, v_shipment.code, v_shipment.mode,
           v_shipment.route, v_shipment.incoterm, v_shipment.cargo, v_shipment.status,
           v_shipment.eta, v_shipment.created_at;
end;
$$;

revoke all on function public.create_shipment_atomic(uuid, text, text, text, text, text, date, numeric, jsonb) from public, anon;
grant execute on function public.create_shipment_atomic(uuid, text, text, text, text, text, date, numeric, jsonb) to authenticated;