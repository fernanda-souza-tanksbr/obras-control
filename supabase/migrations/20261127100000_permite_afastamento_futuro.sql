-- Afastamento futuro no Obras Control (preparacao versionada; NAO aplicar em producao sem homologacao).
-- Nao altera permissoes, conflitos, competencia fechada, Folga de Campo ou Ferias.
-- O guard de alocacoes futuras permanece inalterado.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='30s';

DO $preflight$
DECLARE v_definition text;
BEGIN
  IF to_regprocedure('public.guard_data_lancamento_nao_futura()') IS NULL THEN
    RAISE EXCEPTION 'GUARD_DATA_FUTURA_AUSENTE';
  END IF;
  SELECT pg_get_functiondef('public.guard_data_lancamento_nao_futura()'::regprocedure)
    INTO v_definition;
  IF v_definition NOT LIKE '%TG_TABLE_NAME%'
     OR v_definition NOT LIKE '%DATA_FUTURA_ALOCACAO%'
     OR v_definition NOT LIKE '%DATA_FUTURA_HORAS%'
     OR v_definition NOT LIKE '%''ferias'', ''folga_campo''%'
     OR v_definition LIKE '%''afastamento''%' THEN
    RAISE EXCEPTION 'GUARD_DATA_FUTURA_DIVERGENTE: revisar antes de aplicar';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.registros_horas'::regclass
      AND tgname = 'guard_data_nao_futura'
      AND tgenabled = 'O'
      AND pg_get_triggerdef(oid) LIKE '%BEFORE INSERT OR UPDATE OF data%'
      AND pg_get_triggerdef(oid) LIKE '%public.registros_horas%'
  ) THEN
    RAISE EXCEPTION 'TRIGGER_REGISTROS_HORAS_DIVERGENTE: revisar antes de aplicar';
  END IF;
END
$preflight$;

CREATE OR REPLACE FUNCTION public.guard_data_lancamento_nao_futura()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $function$
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
       AND NOT (
         NEW.tipo_registro = 'falta'
         AND NEW.falta_tipo = 'afastamento'
         AND coalesce(NEW.horas_normais, 0) = 0
         AND coalesce(NEW.horas_extras, 0) = 0
         AND NEW.ausencia IS TRUE
       ) THEN
      RAISE EXCEPTION 'DATA_FUTURA_HORAS: Nao e permitido lancar horas em datas futuras.'
        USING ERRCODE = '22007';
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'guard_data_lancamento_nao_futura nao suporta a tabela %.', TG_TABLE_NAME
    USING ERRCODE = '55000';
END;
$function$;

-- Impede alteracoes posteriores em um afastamento futuro que transformem
-- o registro em horas ou em classificacoes nao permitidas.
-- Executado na mesma transacao; outras regras de conflito/RLS permanecem ativas.
DROP TRIGGER guard_data_nao_futura ON public.registros_horas;
CREATE TRIGGER guard_data_nao_futura
  BEFORE INSERT OR UPDATE OF data, tipo_registro, falta_tipo,
    horas_normais, horas_extras, ausencia
  ON public.registros_horas
  FOR EACH ROW EXECUTE FUNCTION public.guard_data_lancamento_nao_futura();

-- Mantem as mesmas restricoes de EXECUTE da versao anterior.
REVOKE ALL ON FUNCTION public.guard_data_lancamento_nao_futura()
  FROM PUBLIC, anon, authenticated;

DO $postflight$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_trigger
    WHERE tgrelid = 'public.registros_horas'::regclass
      AND tgname = 'guard_data_nao_futura'
      AND tgenabled = 'O'
      AND pg_get_triggerdef(oid) LIKE '%UPDATE OF data, tipo_registro, falta_tipo, horas_normais, horas_extras, ausencia%'
  ) THEN
    RAISE EXCEPTION 'VALIDACAO_TRIGGER_FUTURO_FALHOU';
  END IF;
END
$postflight$;

COMMIT;

-- Validacao apenas de metadados depois da aplicacao supervisionada:
-- SELECT pg_get_functiondef('public.guard_data_lancamento_nao_futura()'::regprocedure);
