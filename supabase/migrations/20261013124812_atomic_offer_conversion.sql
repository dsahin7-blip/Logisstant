create or replace function public.convert_offer_to_shipment(p_offer_id uuid)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
    v_offer public.offers%rowtype;
    v_shipment_id uuid;
    v_mode_prefix text;
begin
    if (select auth.uid()) is null then
        raise exception 'Giriş yapmanız gerekiyor.' using errcode = '28000';
    end if;

    select offer.*
      into v_offer
      from public.offers as offer
     where offer.id = p_offer_id
     for update;

    if not found then
        raise exception 'Teklif bulunamadı veya bu işlem için erişiminiz yok.' using errcode = 'P0002';
    end if;

    if not (select private.has_org_role(
        v_offer.organization_id,
        array['owner', 'admin', 'operations']::text[]
    )) then
        raise exception 'Bu işlem için yetkiniz yok.' using errcode = '42501';
    end if;

    if v_offer.converted_shipment_id is not null then
        return v_offer.converted_shipment_id;
    end if;

    if v_offer.status <> 'Onaylandı' then
        raise exception 'Yalnızca onaylanan teklifler gönderiye dönüştürülebilir.' using errcode = '22023';
    end if;

    if v_offer.valid_until is not null and v_offer.valid_until < current_date then
        raise exception 'Teklifin geçerlilik süresi dolmuş.' using errcode = '22023';
    end if;

    v_mode_prefix := case v_offer.mode
        when 'Denizyolu' then 'SEA-'
        when 'Havayolu' then 'AIR-'
        when 'Demiryolu' then 'RAIL-'
        else 'TR-'
    end;

    insert into public.shipments (
        organization_id,
        customer_id,
        created_by,
        code,
        mode,
        route,
        incoterm,
        cargo,
        status,
        eta,
        documents,
        document_applicability,
        history,
        updated_at
    )
    values (
        v_offer.organization_id,
        v_offer.customer_id,
        (select auth.uid()),
        v_mode_prefix || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
        v_offer.mode,
        btrim(v_offer.route),
        coalesce(v_offer.incoterm, ''),
        coalesce(v_offer.cargo, ''),
        'Yükleme Bekliyor',
        null,
        '{}'::jsonb,
        '{}'::jsonb,
        '[]'::jsonb,
        now()
    )
    returning id into v_shipment_id;

    insert into public.shipment_private (
        shipment_id,
        organization_id,
        internal_data
    )
    values (
        v_shipment_id,
        v_offer.organization_id,
        jsonb_build_object('income', v_offer.amount, 'expense1', 0, 'expense2', 0)
    );

    update public.offers
       set converted_shipment_id = v_shipment_id
     where id = v_offer.id
       and converted_shipment_id is null;

    if not found then
        raise exception 'Teklif gönderiye dönüştürülemedi.' using errcode = '40001';
    end if;

    return v_shipment_id;
end;
$$;

revoke all on function public.convert_offer_to_shipment(uuid) from public, anon;
grant execute on function public.convert_offer_to_shipment(uuid) to authenticated;
