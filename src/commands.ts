export interface BotCommand {
  command: string;
  description: string;
}

/** Commands every agent offers. Also what Telegram's setMyCommands publishes. */
export const BOT_COMMANDS: BotCommand[] = [{ command: 'new', description: 'Начать новый разговор' }];

/**
 * One agent's own quick command. The model never sees the raw `/name`: the
 * host swaps in `prompt(args)` — a direct call of the skill that does the job —
 * so the agent doesn't have to work out what the command means.
 */
export interface AgentCommand {
  /** agent_groups.folder of the only agent that offers it. */
  agent: string;
  /** Without the leading slash. */
  command: string;
  description: string;
  /** What the model gets instead. `args` is the text after the command, trimmed. */
  prompt: (args: string) => string;
  /**
   * Agent scripts (relative to /workspace/agent) the runner runs before the
   * model turn, attaching their output — the model writes from fresh figures
   * instead of spending a tool round trip on collecting them.
   */
  data?: string[];
  /** The app puts the command into the input for the user to finish instead of sending it. */
  input?: 'compose';
  /** The app answers the tap itself, without a chat message. */
  action?: 'today_plan';
}

export const AGENT_COMMANDS: AgentCommand[] = [
  {
    agent: 'jarvis',
    command: 'surf',
    description: 'Прогноз серфинга',
    prompt: (args) => `Прогноз серфинга — сразу скилл surf-forecast.${args ? ` ${args}` : ''}`,
  },
  {
    agent: 'payne',
    command: 'workout',
    description: 'Начать тренировку',
    // The app answers the tap with today's plan card (runner-built, no model).
    // This prompt is for a typed /workout, or a day whose workout is done.
    prompt: (args) => `Начать тренировку — скилл workout-mode.${args ? ` ${args}` : ''}`,
    action: 'today_plan',
  },
  {
    agent: 'gordon',
    command: 'food',
    description: 'Залогировать еду',
    prompt: (args) => `Залогируй еду — сразу скилл log-meal. ${args || 'Что съел — во вложении.'}`,
    input: 'compose',
  },
  {
    agent: 'greg',
    command: 'health',
    description: 'Состояние здоровья',
    prompt: (args) =>
      'Дай вывод о моём состоянии здоровья — коротко, своим голосом. Свежий вывод analyze.js ниже: ' +
      'посчитан только что, повторно не запускай; если его нет — посчитай сам.' +
      (args ? ` ${args}` : ''),
    data: ['scripts/analyze.js'],
  },
  {
    agent: 'scrooge',
    command: 'money',
    description: 'Состояние финансов',
    prompt: (args) =>
      'Дай вывод о состоянии моих финансов — коротко, своим голосом. Свежие analyze.js и networth.js ниже: ' +
      'посчитаны только что, повторно не запускай; если их нет — посчитай сам.' +
      (args ? ` ${args}` : ''),
    data: ['scripts/analyze.js', 'scripts/networth.js'],
  },
];

/** The agent's own command `name` (no slash), or undefined if that agent doesn't offer it. */
export function findAgentCommand(agentFolder: string, name: string): AgentCommand | undefined {
  return AGENT_COMMANDS.find((c) => c.agent === agentFolder && c.command === name);
}

/** One entry of the iOS `auth_ok.commands` catalogue. No `agent_id` = every agent. */
export interface AppCommand {
  command: string;
  description: string;
  agent_id?: string;
  input?: 'compose';
  action?: 'today_plan';
}

/** The catalogue the iOS app gets on auth: the common commands, then each agent's own. */
export function appCommands(): AppCommand[] {
  return [
    ...BOT_COMMANDS.map((c) => ({ command: '/' + c.command, description: c.description })),
    ...AGENT_COMMANDS.map((c) => ({
      command: '/' + c.command,
      description: c.description,
      agent_id: c.agent,
      ...(c.input ? { input: c.input } : {}),
      ...(c.action ? { action: c.action } : {}),
    })),
  ];
}
