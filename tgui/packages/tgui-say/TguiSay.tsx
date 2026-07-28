/**
 * @file
 * Панель ввода сообщений.
 *
 * Держит стопку набираемых сообщений: у каждого свой канал и свой текст.
 * Клавиша канала не отменяет начатое, а добавляет строку рядом — ровно так же
 * себя вёл нативный ввод BYOND, где диалогов можно было открыть сколько
 * угодно, только теперь всё это живёт в одном месте и не теряется за окнами.
 */

import {
  type KeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
} from 'react';

import { flattenNewlines, isCaretOnFirstLine, isCaretOnLastLine } from './caret';
import {
  type Channel,
  isChannel,
  isSayChannel,
  isVisibleChannel,
} from './channels';
import { ChatHistory } from './ChatHistory';
import type { Offset } from './geometry';
import {
  commitOffset,
  currentOffset,
  dragPanelTo,
  hidePanel,
  refreshMapSize,
  resetOffset,
  resizePanel,
  setPlacement,
  showPanel,
} from './helpers';
import { type Hint, Hints } from './Hints';
import { MessageRow } from './MessageRow';
import { dispatchMessage, sendMessage, subscribeTo } from './messages';
import { getPrefix, stripPrefix } from './prefixes';
import {
  activeRow,
  closeRow,
  emptyRows,
  nextFreeChannel,
  openChannel,
  type Row,
  stepActive,
  updateRow,
} from './rows';
import { resetTypingThrottle, shouldSendTyping } from './timers';

type OpenPayload = {
  channel: Channel;
};

type PropsPayload = {
  maxLength: number;
  emotes: string[];
  anchor: string;
  viewTiles: number;
  hudTiles: number;
  radios: Hint[];
  languages: Hint[];
};

/** Обработчики, которые подписки зовут через ref, а не через замыкание. */
type Handlers = {
  open: (channel: Channel) => void;
  hide: () => void;
};

export const TguiSay = () => {
  const [state, setState] = useState(emptyRows());
  const [visible, setVisible] = useState(false);
  const [maxLength, setMaxLength] = useState(4096);
  const [emotes, setEmotes] = useState<string[]>([]);
  const [radios, setRadios] = useState<Hint[]>([]);
  const [languages, setLanguages] = useState<Hint[]>([]);
  // Подсказки закреплены игроком. Иначе они видны, пока строка пуста, и
  // убираются, как только он начал печатать.
  const [hintsPinned, setHintsPinned] = useState(false);

  const rootRef = useRef<HTMLDivElement>(null);
  const inputs = useRef(new Map<number, HTMLTextAreaElement>());
  const histories = useRef(new Map<Channel, ChatHistory>());
  // Строка, которой нужно отдать фокус после ближайшей отрисовки.
  const pendingFocus = useRef<number | null>(null);
  // Нужно ли заново показать панель и забрать фокус у карты.
  const revealRequested = useRef(false);
  // Канал, о котором знает сервер. По нему он ведёт индикатор печати.
  const knownChannel = useRef<Channel | null>(null);
  // Свежие обработчики для подписок: подписки ставятся один раз, а замыкания
  // в них устарели бы уже на следующем рендере.
  const handlers = useRef<Handlers>({
    open: () => {},
    hide: () => {},
  });

  const panelHeight = () => rootRef.current?.getBoundingClientRect().height || 0;

  /**
   * Перетаскивание панели.
   *
   * Панель едет за курсором, поэтому курсор остаётся над ней и браузерный
   * элемент продолжает получать события мыши: отпусти он их хоть на кадр —
   * перетаскивание оборвалось бы на середине.
   */
  const startDrag = (event: ReactMouseEvent) => {
    if (event.button !== 0) {
      return;
    }
    event.preventDefault();
    const startX = event.screenX;
    const startY = event.screenY;
    const base: Offset = currentOffset();
    const move = (moveEvent: MouseEvent) => {
      dragPanelTo(
        moveEvent.screenX - startX,
        moveEvent.screenY - startY,
        base,
        panelHeight(),
      );
    };
    const end = () => {
      document.removeEventListener('mousemove', move);
      document.removeEventListener('mouseup', end);
      commitOffset();
    };
    document.addEventListener('mousemove', move);
    document.addEventListener('mouseup', end);
  };

  const historyFor = (channel: Channel): ChatHistory => {
    let history = histories.current.get(channel);
    if (!history) {
      history = new ChatHistory();
      histories.current.set(channel, history);
    }
    return history;
  };

  const focusLater = (id: number | null) => {
    pendingFocus.current = id;
  };

  const openIn = (channel: Channel) => {
    setState(previous => {
      const next = openChannel(previous, channel);
      focusLater(next.activeId);
      return next;
    });
    // Фокус мог уехать на карту, пока панель висела открытой: забирать его
    // обратно нужно на каждом открытии, а не только на первом.
    revealRequested.current = true;
    setVisible(true);
    knownChannel.current = channel;
    sendMessage('open', { channel });
  };

  /** Прячет панель, не трогая набранное: строки ждут возвращения. */
  const hide = () => {
    setVisible(false);
    hidePanel();
    resetTypingThrottle();
    knownChannel.current = null;
    sendMessage('close');
  };

  const setValue = (id: number, value: string) => {
    setState(previous => updateRow(previous, id, { value }));
  };

  const dropRow = (id: number) => {
    setState(previous => {
      const next = closeRow(previous, id);
      if (!next.rows.length) {
        // Прятать панель прямо здесь нельзя: setState обязан оставаться чистым.
        pendingFocus.current = null;
      }
      else {
        focusLater(next.activeId);
      }
      return next;
    });
  };

  const submit = (row: Row) => {
    const entry = flattenNewlines(row.value);
    if (entry.length) {
      historyFor(row.channel).add(entry);
      // Префикс возвращается в строку в латинском виде: разбор каналов
      // остаётся на сервере и о раскладке игрока ничего не знает.
      const payload
        = row.prefix && isSayChannel(row.channel)
          ? row.prefix.token + entry
          : entry;
      sendMessage('entry', { channel: row.channel, entry: payload });
    }
    dropRow(row.id);
  };

  const cycleChannel = (row: Row) => {
    setState(previous =>
      updateRow(previous, row.id, {
        channel: nextFreeChannel(previous, row.id),
        prefix: null,
      }),
    );
    focusLater(row.id);
  };

  const step = (delta: number) => {
    setState(previous => {
      const next = stepActive(previous, delta);
      focusLater(next.activeId);
      return next;
    });
  };

  const handleInput = (row: Row, typed: string) => {
    // Как только человек начал править вытащенное из истории, текст становится
    // его собственным: дальше стрелки его уже не тронут.
    const history = historyFor(row.channel);
    if (!history.isAtLatest()) {
      history.reset();
    }
    // Индикатор печати зажигается по набору, а не по открытию панели: иначе
    // пузырь висит над теми, кто открыл её и передумал.
    if (isVisibleChannel(row.channel) && shouldSendTyping(Date.now())) {
      sendMessage('typing');
    }
    // Префикс ловим только в речи и только пока он не выбран: дальше символы
    // ":" и ";" — это обычный текст.
    if (!row.prefix && isSayChannel(row.channel)) {
      const found = getPrefix(typed);
      if (found) {
        setState(previous =>
          updateRow(previous, row.id, {
            prefix: found,
            value: stripPrefix(typed),
          }),
        );
        return;
      }
    }
    setValue(row.id, typed);
  };

  const browseHistory = (row: Row, direction: number) => {
    const history = historyFor(row.channel);
    if (direction < 0) {
      if (history.isAtLatest()) {
        history.saveTemp(row.value);
      }
      const older = history.getOlderMessage();
      if (older !== null) {
        setValue(row.id, older);
      }
      return;
    }
    const newer = history.getNewerMessage();
    setValue(row.id, newer !== null ? newer : history.getTemp());
  };

  const handleKeyDown = (row: Row) => (event: KeyboardEvent<HTMLTextAreaElement>) => {
    const element = event.currentTarget;
    switch (event.key) {
      case 'Enter':
        if (event.shiftKey) {
          return;
        }
        event.preventDefault();
        submit(row);
        return;
      case 'Tab':
        event.preventDefault();
        if (event.ctrlKey || event.shiftKey) {
          step(event.shiftKey ? -1 : 1);
          return;
        }
        cycleChannel(row);
        return;
      case 'Escape':
        event.preventDefault();
        if (event.shiftKey) {
          dropRow(row.id);
          return;
        }
        hide();
        return;
      case 'ArrowUp':
      case 'ArrowDown': {
        const direction = event.key === 'ArrowUp' ? -1 : 1;
        if (event.ctrlKey) {
          event.preventDefault();
          step(direction);
          return;
        }
        // Набранное дороже истории. Пока в поле лежит свой текст, стрелка не
        // имеет права его подменить: случайное нажатие стирало реплику,
        // которую человек писал минуту.
        if (row.value.length && historyFor(row.channel).isAtLatest()) {
          return;
        }
        const caret = {
          value: element.value,
          selectionStart: element.selectionStart,
          selectionEnd: element.selectionEnd,
        };
        // В многострочном тексте стрелки сначала ходят по нему самому.
        if (direction < 0 ? !isCaretOnFirstLine(caret) : !isCaretOnLastLine(caret)) {
          return;
        }
        event.preventDefault();
        browseHistory(row, direction);
        return;
      }
      case 'Backspace':
      case 'Delete':
        // Стирание на пустом поле снимает выбранный префикс рации.
        if (row.prefix && !row.value.length) {
          setState(previous => updateRow(previous, row.id, { prefix: null }));
        }
    }
  };

  useEffect(() => {
    handlers.current.open = openIn;
    handlers.current.hide = hide;
  });

  useEffect(() => {
    subscribeTo('props', (payload: PropsPayload) => {
      if (payload?.maxLength) {
        setMaxLength(payload.maxLength);
      }
      if (payload?.emotes) {
        setEmotes(payload.emotes);
      }
      setRadios(payload?.radios || []);
      setLanguages(payload?.languages || []);
      setPlacement(payload?.anchor, payload?.viewTiles, payload?.hudTiles);
      // Настройку могли сменить прямо сейчас, глядя на панель.
      if (rootRef.current) {
        resizePanel(rootRef.current.getBoundingClientRect().height);
      }
    });
    subscribeTo('open', (payload: OpenPayload) => {
      const channel = isChannel(payload?.channel) ? payload.channel : 'Say';
      handlers.current.open(channel);
    });
    subscribeTo('close', () => handlers.current.hide());
    // Сообщения, пришедшие до монтирования, лежат в очереди шима.
    window.update = dispatchMessage;
    while (true) {
      const queued = window.__updateQueue__?.shift();
      if (!queued) {
        break;
      }
      dispatchMessage(queued);
    }
    refreshMapSize();
    sendMessage('ready');
  }, []);

  // Панель обязана быть ровно по высоте содержимого: лишняя высота закрывает
  // собой карту чёрным прямоугольником.
  useLayoutEffect(() => {
    if (!visible) {
      return;
    }
    const height = rootRef.current?.getBoundingClientRect().height || 0;
    if (!height) {
      return;
    }
    if (!revealRequested.current) {
      resizePanel(height);
      return;
    }
    revealRequested.current = false;
    showPanel(height);
    // Карту могли растянуть, пока панель была спрятана. Открытие этого не
    // ждёт: панель появляется сразу, а на место встаёт следующим кадром.
    refreshMapSize().then(() => {
      const current = rootRef.current?.getBoundingClientRect().height || height;
      resizePanel(current);
    });
  });

  // Фокус ставим после того, как панель стала видимой: BYOND не отдаёт фокус
  // скрытому элементу.
  useLayoutEffect(() => {
    const id = pendingFocus.current;
    if (id === null || !visible) {
      return;
    }
    pendingFocus.current = null;
    const element = inputs.current.get(id);
    if (!element) {
      return;
    }
    setTimeout(() => {
      element.focus();
      const caret = element.value.length;
      element.setSelectionRange(caret, caret);
    }, 0);
  });

  // Последняя строка ушла — панели больше нечего показывать.
  useEffect(() => {
    if (visible && !state.rows.length) {
      hide();
    }
  }, [state.rows.length, visible]);

  // Индикатор печати идёт по активной строке: сервер обязан знать, куда
  // именно человек сейчас пишет.
  useEffect(() => {
    if (!visible) {
      return;
    }
    const row = activeRow(state);
    if (!row || row.channel === knownChannel.current) {
      return;
    }
    knownChannel.current = row.channel;
    sendMessage('channel', { channel: row.channel });
  });

  const current = activeRow(state);
  // Подсказки показываются, пока строка пуста: открыл панель — увидел свои
  // каналы, начал печатать — они ушли, чтобы не занимать полкарты.
  //
  // И только в речи: префиксы разбираются на её пути, а в эмоции или OOC
  // ведут себя как обычный текст — подсказывать там нечего.
  const hintsShown
    = !!current
    && isSayChannel(current.channel)
    && (hintsPinned || !current.value.length);

  const insertToken = (token: string) => {
    if (!current) {
      return;
    }
    setValue(current.id, token + current.value);
    focusLater(current.id);
  };

  return (
    <div className="Say" ref={rootRef}>
      {hintsShown && (
        <Hints languages={languages} onPick={insertToken} radios={radios} />
      )}
      <div className="Say__rows">
        {state.rows.map(row => (
          <MessageRow
            active={row.id === state.activeId}
            emotes={emotes}
            key={row.id}
            maxLength={maxLength}
            onActivate={() => setState(previous => ({ ...previous, activeId: row.id }))}
            onChange={value => handleInput(row, value)}
            onClose={() => dropRow(row.id)}
            onCycleChannel={() => cycleChannel(row)}
            onKeyDown={handleKeyDown(row)}
            onPick={emote => {
              setValue(row.id, `*${emote}`);
              focusLater(row.id);
            }}
            registerInput={element => {
              if (element) {
                inputs.current.set(row.id, element);
              }
              else {
                inputs.current.delete(row.id);
              }
            }}
            row={row}
          />
        ))}
      </div>
      <div
        className="Say__footer"
        onDoubleClick={() => resetOffset(panelHeight())}
        onMouseDown={startDrag}
        title="Перетащи, чтобы передвинуть панель. Двойной щелчок вернёт её на место">
        <span className="Say__grip">⠿</span>
        <span><b>Enter</b> отправить</span>
        <span><b>Shift+Enter</b> перенос</span>
        <span><b>Tab</b> канал</span>
        {state.rows.length > 1 && <span><b>Ctrl+↑↓</b> между строками</span>}
        <span><b>Esc</b> свернуть</span>
        <button
          className={`Say__help${hintsPinned ? ' Say__help--on' : ''}`}
          onClick={() => setHintsPinned(pinned => !pinned)}
          onMouseDown={event => event.stopPropagation()}
          title="Подсказки по префиксам"
          type="button">
          ?
        </button>
      </div>
    </div>
  );
};
