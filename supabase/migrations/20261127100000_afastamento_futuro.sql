-- PREPARACAO: NAO APLICAR AUTOMATICAMENTE EM PRODUCAO.
-- Afastamento pode ocorrer em datas futuras sem habilitar horas/alocacoes futuras.
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

CREATE OR REPLACE FUNCTION public.guard_data_lancamento_nao_futura()
RETURNS trigger
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = pg_catalog, public
AS $guard$
BEGIN
  IF TG_TABLE_NAME = 'alocacoes' THEN
    IF NEW.data > current_date THEN
      RAISE EXCEPTION 'DATA_FUTURA_ALOCACAO: Nao e permitido lancar alocacoes em datas futuras.'
        USING ERRCODE = '22007';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'registros_horas' THEN
    IF NEW.data > current_date
       AND NEW.tipo_registro NOT IN ('ferias', 'folga_campo')
       AND NOT (NEW.tipo_registro = 'falta' AND NEW.falta_tipo = 'afastamento'
                AND coalesce(NEW.horas_normais, 0) = 0
                AND coalesce(NEW.horas_extras, 0) = 0) THEN
      RAISE EXCEPTION 'DATA_FUTURA_HORAS: Nao e permitido lancar horas em datas futuras.'
        USING ERRCODE = '22007';
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'guard_data_lancamento_nao_futura nao suporta a tabela %.', TG_TABLE_NAME
    USING ERRCODE = '55000';
END;
$guard$;

-- Transacao unica e invoker: preserva RLS, triggers de conflito e competencia.
CREATE OR REPLACE FUNCTION public.obras_salvar_afastamento_periodo(
  p_funcionario_id uuid,
  p_obra_id uuid,
  p_data_inicio date,
  p_data_fim date,
  p_observacoes text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql SECURITY INVOKER
SET search_path = public, pg_temp
AS $periodo$
DECLARE
  v_usuario uuid := auth.uid();
  v_data date;
  v_total integer;
BEGIN
  IF v_usuario IS NULL THEN
    RAISE EXCEPTION 'Autenticacao obrigatoria.' USING ERRCODE = '42501';
  END IF;
  IF p_funcionario_id IS NULL OR p_obra_id IS NULL THEN
    RAISE EXCEPTION 'Funcionario e obra sao obrigatorios.' USING ERRCODE = '23514';
  END IF;
  IF p_data_inicio IS NULL OR p_data_fim IS NULL
     OR p_data_fim < p_data_inicio THEN
    RAISE EXCEPTION 'PERIODO_AFASTAMENTO_INVALIDO' USING ERRCODE = '22007';
  END IF;
  IF p_data_fim - p_data_inicio >= 92 THEN
    RAISE EXCEPTION 'PERIODO_AFASTAMENTO_LIMITE_92_DIAS' USING ERRCODE = '22023';
  END IF;

  -- Ordenacao de locks por funcionario/data para evitar corrida e deadlock.
  FOR v_data IN
    SELECT d::date
    FROM generate_series(p_data_inicio, p_data_fim, interval '1 day') AS d
    ORDER BY d
  LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(p_funcionario_id::text || '|' || v_data::text, 0)
    );
    IF EXISTS (
      SELECT 1 FROM public.alocacoes a
      WHERE a.funcionario_id = p_funcionario_id AND a.data = v_data
    ) OR EXISTS (
      SELECT 1 FROM public.registros_horas r
      WHERE r.funcionario_id = p_funcionario_id AND r.data = v_data
    ) THEN
      RAISE EXCEPTION 'REGISTRO_AFASTAMENTO_CONFLITO: %', v_data
        USING ERRCODE = '23514';
    END IF;
    -- Triggers de validacao da tabela tambem verificam conflitos e competencias.
  END LOOP;

  INSERT INTO public.registros_horas (
    funcionario_id, obra_id, data, tipo_registro, falta_tipo,
    horas_normais, horas_extras, justificativa_extras, ausencia,
    motivo_ausencia, observacoes, created_by, updated_by
  )
  SELECT p_funcionario_id, p_obra_id, d::date, 'falta', 'afastamento',
         0, 0, NULL, true, NULL, nullif(btrim(p_observacoes), ''),
         v_usuario, v_usuario
  FROM generate_series(p_data_inicio, p_data_fim, interval '1 day') AS d;

  GET DIAGNOSTICS v_total = ROW_COUNT;
  RETURN v_total;
END;
$periodo$;

REVOKE ALL ON FUNCTION public.obras_salvar_afastamento_periodo(uuid,uuid,date,date,text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obras_salvar_afastamento_periodo(uuid,uuid,date,date,text)
  TO authenticated;

COMMENT ON FUNCTION public.obras_salvar_afastamento_periodo(uuid,uuid,date,date,text)
  IS 'Registra Afastamento por dias corridos, inclusive futuros, sem horas ou alocacoes e preservando RLS/conflitos.';
COMMIT;
