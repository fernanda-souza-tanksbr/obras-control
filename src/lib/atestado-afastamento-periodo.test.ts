import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dataLancamentoFutura } from "./data-lancamento.ts";
import test from "node:test";

import {
  enumerarDiasCorridos,
  afastamentoPermiteDataFutura,
  faltaPermitePeriodo,
  normalizarTipoRegistroPeriodo,
} from "./registro-falta.ts";

const componente = readFileSync("src/components/AlocarPeriodoDialog.tsx", "utf8");

test("atestado de um dia mantém o registro diário atual", () => {
  assert.deepEqual(enumerarDiasCorridos("2026-09-02", "2026-09-02"), ["2026-09-02"]);
  assert.deepEqual(normalizarTipoRegistroPeriodo("atestado"), {
    tipoRegistro: "falta",
    faltaTipo: "atestado",
  });
});

test("atestado e afastamento aceitam período inclusivo com fins de semana", () => {
  assert.deepEqual(enumerarDiasCorridos("2026-09-04", "2026-09-07"), [
    "2026-09-04",
    "2026-09-05",
    "2026-09-06",
    "2026-09-07",
  ]);
  assert.equal(faltaPermitePeriodo("atestado"), true);
  assert.deepEqual(normalizarTipoRegistroPeriodo("afastamento"), {
    tipoRegistro: "falta",
    faltaTipo: "afastamento",
  });
});

test("intervalo invertido é inválido e não enumera dias", () => {
  assert.deepEqual(enumerarDiasCorridos("2026-09-03", "2026-09-02"), []);
  assert.match(componente, /Data final deve ser igual ou posterior à inicial/);
});

test("período preserva conflitos, revalida concorrência e relata resultado parcial", () => {
  assert.match(componente, /const diasAlvo =[\s\S]*?!setA\.has\(d\)[\s\S]*?!setR\.has\(d\)/);
  assert.match(componente, /ocupadosConcorrentes/);
  assert.match(componente, /ignoreDuplicates: true/);
  assert.match(componente, /Os lançamentos existentes foram preservados/);
  assert.match(componente, /!faltaPeriodo && \(/);
});

test("atestado e afastamento reutilizam RPC e regras diárias sem alterar horas normais", () => {
  assert.match(componente, /rpc\("obras_salvar_registro_horas"/);
  assert.match(componente, /p_falta_tipo: faltaTipo/);
  assert.match(componente, /p_horas_normais: 0/);
  assert.match(componente, /p_horas_extras: 0/);
  assert.match(componente, /garantirCompetenciaAberta\(supabase, data\)/);
  assert.match(componente, /calcularJornadaDetalhada/);
});

const migrationFuturo = readFileSync(
  "supabase/migrations/20261127100000_permite_afastamento_futuro.sql",
  "utf8",
);
const telaDiaria = readFileSync("src/routes/_authenticated/alocacoes.tsx", "utf8");

test("afastamento pode iniciar hoje e terminar no futuro, inclusive fim de semana", () => {
  assert.deepEqual(enumerarDiasCorridos("2026-11-27", "2026-11-30"), [
    "2026-11-27", "2026-11-28", "2026-11-29", "2026-11-30",
  ]);
  assert.equal(afastamentoPermiteDataFutura("afastamento"), true);
  assert.equal(dataLancamentoFutura("2026-11-30", "2026-11-27"), true);
});

test("afastamento aceita periodo integralmente futuro; atestado e horas seguem bloqueados", () => {
  assert.deepEqual(enumerarDiasCorridos("2026-12-05", "2026-12-07"), [
    "2026-12-05", "2026-12-06", "2026-12-07",
  ]);
  for (const tipo of ["atestado", "horas", "falta", "outro"]) {
    assert.equal(afastamentoPermiteDataFutura(tipo), false);
  }
  assert.match(componente, /max=\\{permiteDataFutura \? undefined : today\\}/);
  assert.match(componente, /if \(!permiteDataFutura\)/);
  assert.match(telaDiaria, /permiteAfastamentoFuturo = watchTipoRegistro === "falta" && watchFaltaTipo === "afastamento"/);
  assert.match(telaDiaria, /if \(!\(v.tipo_registro === "falta" && v.falta_tipo === "afastamento"\)\)/);
});

test("futuro de afastamento nao cria alocacoes ou horas e preserva conflitos existentes", () => {
  assert.match(componente, /if \(!\(afastamentoPermiteDataFutura\(tipoRegistro\) && data > today\)\)/);
  assert.match(componente, /p_horas_normais: 0/);
  assert.match(componente, /p_horas_extras: 0/);
  assert.match(componente, /ocupadosConcorrentes/);
  assert.match(componente, /buscarConflitosAlocacao/);
  assert.match(componente, /garantirCompetenciaAberta\(supabase, data\)/);
  assert.match(migrationFuturo, /NEW.tipo_registro = 'falta'/);
  assert.match(migrationFuturo, /NEW.falta_tipo = 'afastamento'/);
  assert.match(migrationFuturo, /NEW.horas_normais, 0\) = 0/);
  assert.match(migrationFuturo, /NEW.horas_extras, 0\) = 0/);
  assert.match(migrationFuturo, /NEW.ausencia IS TRUE/);
  assert.match(migrationFuturo, /DATA_FUTURA_ALOCACAO/);
  assert.match(migrationFuturo, /REVOKE ALL ON FUNCTION/);
  assert.doesNotMatch(migrationFuturo, /GRANT EXECUTE/);
});
