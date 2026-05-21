export interface BotCommand {
  command: string;
  description: string;
}

export const BOT_COMMANDS: BotCommand[] = [
  { command: 'new',    description: 'Начать новый разговор' },
  { command: 'tasks',  description: 'Список задач' },
  { command: 'people', description: 'Список людей в памяти' },
  { command: 'find',   description: 'Найти человека: /find Имя' },
  { command: 'surf',   description: 'Прогноз серфинга' },
  { command: 'status', description: 'Статус системы' },
  { command: 'memory', description: 'Показать профиль' },
];
