/**
 * @file
 * Подсказки по префиксам.
 *
 * Рации приходят с сервера: у каждого игрока свой набор каналов, и угадывать
 * его по памяти — то, чем не должен заниматься никто. Модификаторы речи
 * перечислены здесь, потому что они одинаковы для всех и живут в разборе
 * сообщения (get_message_mode в code/modules/mob/say.dm).
 */

export type Hint = {
  token: string;
  name: string;
};

type Props = {
  radios: Hint[];
  languages: Hint[];
  onPick: (token: string) => void;
};

/**
 * Русские названия каналов.
 *
 * С сервера они приходят такими, как записаны в RADIO_CHANNEL_* — по-английски.
 * Неизвестное название показывается как есть: лучше английское, чем никакого.
 */
const CHANNEL_NAMES: Record<string, string> = {
  Common: 'Общий',
  Command: 'Командный',
  Science: 'Наука',
  Medical: 'Медицина',
  Engineering: 'Инженерный',
  Security: 'СБ',
  Supply: 'Снабжение',
  Service: 'Сервис',
  Syndicate: 'Синдикат',
  CentCom: 'ЦК',
  'AI Private': 'Канал ИИ',
  Binary: 'Бинарный',
  Pirate: 'Пираты',
  InteQ: 'InteQ',
};

const MODIFIERS: Hint[] = [
  { token: '*', name: 'эмоут' },
  { token: '#', name: 'шёпот' },
  { token: '%', name: 'пение' },
];

const Group = (props: { label: string; items: Hint[]; onPick: (token: string) => void }) => {
  if (!props.items.length) {
    return null;
  }
  return (
    <div className="Say__hintGroup">
      <span className="Say__hintLabel">{props.label}</span>
      {props.items.map(item => (
        <button
          className="Say__hint"
          key={item.token + item.name}
          // Перетаскивание панели начинается на нижней строке: не даём
          // нажатию на подсказку утянуть за собой всю панель.
          onMouseDown={event => event.stopPropagation()}
          onClick={() => props.onPick(item.token)}
          type="button">
          <b>{item.token}</b> {item.name}
        </button>
      ))}
    </div>
  );
};

export const Hints = (props: Props) => {
  const radios = props.radios.map(hint => ({
    token: hint.token,
    name: CHANNEL_NAMES[hint.name] || hint.name,
  }));

  return (
    <div className="Say__hintPanel">
      <Group items={radios} label="Рация" onPick={props.onPick} />
      <Group items={MODIFIERS} label="Текст" onPick={props.onPick} />
      <Group items={props.languages} label="Язык" onPick={props.onPick} />
      <div className="Say__hintGroup">
        <span className="Say__hintLabel">Ещё</span>
        <span className="Say__hintNote">
          <b>глагол*</b> своя подача речи
        </span>
      </div>
    </div>
  );
};
