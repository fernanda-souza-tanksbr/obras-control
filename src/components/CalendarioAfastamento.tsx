import { useState } from "react";
import { CalendarDays } from "lucide-react";
import { ptBR } from "date-fns/locale";

import { Button } from "@/components/ui/button";
import { Calendar } from "@/components/ui/calendar";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";

type Props = {
  value: string;
  onChange: (value: string) => void;
  label: string;
};

function dataLocalISO(data: Date): string {
  return `${data.getFullYear()}-${String(data.getMonth() + 1).padStart(2, "0")}-${String(
    data.getDate(),
  ).padStart(2, "0")}`;
}

export function CalendarioAfastamento({ value, onChange, label }: Props) {
  const [open, setOpen] = useState(false);
  // Meio-dia local evita deslocamento de data ao converter entre fusos.
  const selecionada = value ? new Date(`${value}T12:00:00`) : undefined;
  const dataValida = selecionada && !Number.isNaN(selecionada.getTime()) ? selecionada : undefined;

  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger asChild>
        <Button
          type="button"
          variant="outline"
          aria-label={`Selecionar data ${label.toLowerCase()} do afastamento`}
          className="h-9 w-full justify-between px-3 font-normal"
        >
          {dataValida ? dataValida.toLocaleDateString("pt-BR") : "Selecione uma data"}
          <CalendarDays className="ml-2 h-4 w-4 shrink-0" />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" side="bottom" className="w-auto max-w-[calc(100vw-2rem)] p-0">
        <Calendar
          mode="single"
          locale={ptBR}
          selected={dataValida}
          defaultMonth={dataValida}
          onSelect={(data) => {
            if (!data) return;
            onChange(dataLocalISO(data));
            setOpen(false);
          }}
          // Afastamento nao possui limite de data futura.
          showOutsideDays
          initialFocus
        />
      </PopoverContent>
    </Popover>
  );
}
