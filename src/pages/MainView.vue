<script setup lang="ts">
import { computed, ref, shallowRef, watch, onUnmounted } from 'vue';
import { refDebounced, onClickOutside } from '@vueuse/core';
import { useFuse } from '@vueuse/integrations/useFuse';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { invoke } from '@tauri-apps/api/core';
import { emit } from '@tauri-apps/api/event';
import { useFetchGameList } from '@/composables/fetch-gamelist';
import { useGlobalState } from '@/composables/app-state';
import type { Game } from '@/types/types';
import WispLogo from '@/components/WispLogo.vue';

const { gameDB, isLoading, allFetchDone } = useFetchGameList();
const { addLog } = useGlobalState();

const searchQuery = shallowRef('');
const debouncedSearchQuery = refDebounced(searchQuery, 180);
const searchResultsIsOpen = ref(false);
const searchContainerRef = ref<HTMLElement | null>(null);

const isSpoofingEnabled = ref(false);

const activeGame = ref<Game | null>(null);
const activeExecutable = ref<GameExecutable | null>(null);
const isConnectedToRPC = ref(false);
const isConnecting = ref(false);

// Elapsed time counter
const elapsedSeconds = ref(0);
let elapsedTimer: ReturnType<typeof setInterval> | null = null;

function startElapsedTimer() {
  stopElapsedTimer();
  elapsedSeconds.value = 0;
  elapsedTimer = setInterval(() => {
    elapsedSeconds.value++;
  }, 1000);
}

function stopElapsedTimer() {
  if (elapsedTimer) {
    clearInterval(elapsedTimer);
    elapsedTimer = null;
  }
  elapsedSeconds.value = 0;
}

const formattedElapsed = computed(() => {
  const total = elapsedSeconds.value;
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (n: number) => n.toString().padStart(2, '0');
  if (hours > 0) {
    return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  }
  return `${minutes}:${pad(seconds)}`;
});

onUnmounted(() => {
  stopElapsedTimer();
});

onClickOutside(searchContainerRef, () => {
  searchResultsIsOpen.value = false;
});

const fuseOptions = computed(() => ({
  fuseOptions: {
    keys: ['name', 'aliases'],
    isCaseSensitive: false,
    threshold: 0.3,
    ignoreLocation: true,
    minMatchCharLength: 2,
  },
  resultLimit: 6,
}));

const { results: searchResults } = useFuse(debouncedSearchQuery, gameDB, fuseOptions);

function cleanExeName(name: string): string {
  // Strip leading regex-like characters (>, ^, etc.)
  let clean = name.replace(/^[>^<\(]+/, '');
  // Strip (?i) case-insensitive flags
  clean = clean.replace(/\(\?[a-z]+\)/g, '');
  // Strip trailing $ anchor
  clean = clean.replace(/\$$/, '');
  return clean.trim();
}

function hasIllegalChars(p: string): boolean {
  // Characters illegal in Windows filenames/paths (EXCLUDING : \ / which are valid path separators)
  const illegalChars = ['"', '|', '?', '*', '<', '>'];
  return illegalChars.some((char) => p.includes(char));
}

function getFirstValidExecutable(game: Game): GameExecutable {
  if (!game.executables || game.executables.length === 0) {
    return generateDummyExecutable(game);
  }

  const winExecs = game.executables.filter((e) => e.os === 'win32');
  if (winExecs.length === 0) {
    return generateDummyExecutable(game);
  }

  // Score each exe: lower is better
  // Prefer: simple filename (no path separators), no illegal chars after cleaning, no arguments required
  function scoreExe(e: typeof winExecs[0]): number {
    const cleaned = cleanExeName(e.name);
    let score = 0;
    // Has path separators = deeper nesting, less ideal
    const hasPath = cleaned.includes('\\') || cleaned.includes('/');
    if (hasPath) score += 10;
    // Has illegal chars after cleaning
    if (hasIllegalChars(cleaned)) score += 100;
    // Requires arguments (e.g. javaw.exe needs net.minecraft... args)
    if (e.arguments) score += 5;
    // Original name had regex-like prefix
    if (/^[>^<]/.test(e.name)) score += 3;
    return score;
  }

  // Sort by score ascending (best first)
  const sorted = [...winExecs].sort((a, b) => scoreExe(a) - scoreExe(b));
  const chosen = sorted[0];
  
  const cleanedName = cleanExeName(chosen.name);
  
  // If still has illegal chars, fall back to dummy
  if (hasIllegalChars(cleanedName)) {
    return generateDummyExecutable(game);
  }

  // Split into path + filename
  const parts = cleanedName.split(/[/\\]+/);
  const filename = parts.pop() || 'game.exe';
  const subPath = parts.join('\\');
  
  // Build a fake install path
  const safeName = game.name.replace(/[^a-zA-Z0-9 ]/g, '').trim().replace(/\s+/g, '');
  const installPath = subPath
    ? `C:\\Program Files\\${safeName}\\${subPath}`
    : `C:\\Program Files\\${safeName}`;

  return {
    ...chosen,
    name: cleanedName,
    filename,
    path: installPath,
    segments: 3,
    arguments: chosen.arguments,
  };
}

function generateDummyExecutable(game: Game): GameExecutable {
  const dummyName = game.name.replace(/[^a-zA-Z0-9]/g, '');
  const dummyFilename = dummyName.length > 0 ? `${dummyName}.exe` : 'game.exe';
  return {
    is_launcher: false,
    name: `C:\\Program Files\\${dummyName}\\${dummyFilename}`,
    os: 'win32',
    filename: dummyFilename,
    path: `C:\\Program Files\\${dummyName}`,
    segments: 3,
  };
}


async function selectAndPlayGame(game: Game) {
  searchQuery.value = '';
  searchResultsIsOpen.value = false;

  if (activeGame.value) {
    await stopPlaying();
  }

  activeGame.value = game;
  isConnecting.value = true;
  addLog('info', `Starting ${game.name}...`);

  try {
    // Start RPC connection immediately so Discord shows the game right away
    const rpcPromise = invoke('connect_to_discord_rpc_3', {
      activity_json: JSON.stringify({ app_id: game.id }),
      action: 'connect',
    });

    // Run spoofing in parallel (don't block RPC)
    if (isSpoofingEnabled.value) {
      const exec = getFirstValidExecutable(game);
      activeExecutable.value = exec;

      // Spoofing runs in background, doesn't delay Discord presence
      (async () => {
        try {
          await invoke('create_fake_game', {
            path: exec.path || '',
            executable_name: exec.filename || 'game.exe',
            path_len: exec.segments || 1,
            app_id: game.id,
          });

          await invoke('run_background_process', {
            name: game.name,
            path: exec.path || '',
            executable_name: exec.filename || 'game.exe',
            path_len: exec.segments || 1,
            app_id: game.id,
            exec_args: exec.arguments || '',
          });
          addLog('info', `Dummy process started: ${exec.filename}`);
        } catch (err) {
          addLog('error', `Spoofing failed: ${err}`);
        }
      })();
    } else {
      activeExecutable.value = null;
    }

    await rpcPromise;
    isConnectedToRPC.value = true;
    startElapsedTimer();
    addLog('info', `Connected for ${game.name}`);
  } catch (error) {
    addLog('error', `Failed to start game broadcast: ${error}`);
    activeGame.value = null;
    activeExecutable.value = null;
  } finally {
    isConnecting.value = false;
  }
}

async function stopPlaying() {
  if (!activeGame.value) return;
  const gameName = activeGame.value.name;

  addLog('info', `Stopping ${gameName}...`);
  emit('event_disconnect');
  isConnectedToRPC.value = false;
  stopElapsedTimer();

  if (activeExecutable.value && activeExecutable.value.filename) {
    try {
      await invoke('stop_process', { exec_name: activeExecutable.value.filename });
      addLog('info', `Stopped dummy process: ${activeExecutable.value.filename}`);
    } catch (error) {
      addLog('error', `Failed to stop dummy process: ${error}`);
    }
  }

  activeGame.value = null;
  activeExecutable.value = null;
}

watch(isSpoofingEnabled, async (newValue) => {
  if (!activeGame.value) return;

  if (newValue) {
    const exec = getFirstValidExecutable(activeGame.value);
    activeExecutable.value = exec;

    try {
      await invoke('create_fake_game', {
        path: exec.path || '',
        executable_name: exec.filename || 'game.exe',
        path_len: exec.segments || 1,
        app_id: activeGame.value.id,
      });

      await invoke('run_background_process', {
        name: activeGame.value.name,
        path: exec.path || '',
        executable_name: exec.filename || 'game.exe',
        path_len: exec.segments || 1,
        app_id: activeGame.value.id,
        exec_args: exec.arguments || '',
      });
      addLog('info', `Dummy process started: ${exec.filename}`);
    } catch (error) {
      addLog('error', `Failed to start dummy process: ${error}`);
    }
  } else {
    // Turned OFF while broadcasting
    if (activeExecutable.value && activeExecutable.value.filename) {
      try {
        await invoke('stop_process', { exec_name: activeExecutable.value.filename });
        addLog('info', `Stopped dummy process: ${activeExecutable.value.filename}`);
      } catch (error) {
        addLog('error', `Failed to stop dummy process: ${error}`);
      }
      activeExecutable.value = null;
    }
  }
});

const appWindow = getCurrentWindow();

async function startDrag() {
  await appWindow.startDragging();
}

async function minimizeWindow() {
  try {
    await appWindow.minimize();
  } catch (e) {
    console.error('minimize failed', e);
  }
}

async function closeWindow() {
  try {
    await appWindow.close();
  } catch (e) {
    console.error('close failed', e);
  }
}
</script>

<template>
  <div class="h-screen w-screen bg-transparent overflow-hidden">
    <div
      class="relative flex h-full flex-col overflow-hidden rounded-[20px] border border-white/[0.08] bg-bg-main/95 shadow-2xl shadow-black/50 backdrop-blur-2xl"
    >
      <!-- Background Glows -->
      <div class="pointer-events-none absolute inset-0 overflow-hidden">
        <div class="absolute -left-28 -top-24 h-72 w-72 rounded-full bg-primary/15 blur-[90px]"></div>
        <div class="absolute -bottom-32 -right-20 h-80 w-80 rounded-full bg-accent/10 blur-[110px]"></div>
        <div class="absolute left-[45%] top-[38%] h-44 w-44 rounded-full bg-primary-dark/10 blur-[80px]"></div>
      </div>

      <!-- Header (drag region + window controls) -->
      <header
        class="relative z-20 flex h-10 shrink-0 items-center px-3"
      >
        <div class="flex-1 h-full" @mousedown="startDrag"></div>
        <div class="flex items-center gap-1">
          <button
            type="button"
            class="flex h-7 w-7 items-center justify-center rounded-lg text-text-muted transition hover:bg-white/[0.07] hover:text-text-main"
            @mousedown.stop.prevent="minimizeWindow"
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M5 12h14" />
            </svg>
          </button>
          <button
            type="button"
            class="flex h-7 w-7 items-center justify-center rounded-lg text-text-muted transition hover:bg-danger/90 hover:text-white"
            @mousedown.stop.prevent="closeWindow"
          >
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
      </header>

      <!-- Main Content -->
      <main class="relative z-10 flex min-h-0 flex-1 flex-col px-8 pb-6 overflow-y-auto pt-8">
        
        <div class="flex flex-col items-center w-full max-w-lg mx-auto m-auto min-h-[400px]">
          <!-- Logo & Title (also draggable) -->
          <div class="mb-6 flex flex-col items-center select-none">
            <div class="mb-4">
              <WispLogo :size="64" />
            </div>
          <h1 class="text-3xl font-bold tracking-tight text-[#3b82f6]">Wisp</h1>
        </div>

        <!-- Search & Toggle Section -->
        <div class="w-full max-w-lg mb-8">
          <div ref="searchContainerRef" class="relative mb-6">
            <svg
              class="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-text-muted"
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            >
              <circle cx="11" cy="11" r="8" />
              <path d="m21 21-4.35-4.35" />
            </svg>
            <input
              v-model="searchQuery"
              type="search"
              :placeholder="isLoading ? 'Loading catalog...' : 'Search a game...'"
              :disabled="isLoading"
              class="h-12 w-full rounded-[16px] border border-white/[0.09] bg-black/20 pl-12 pr-4 text-[15px] text-text-main outline-none transition placeholder:text-text-muted/70 focus:border-primary/50 focus:ring-4 focus:ring-primary/10 disabled:cursor-not-allowed disabled:opacity-50 shadow-inner"
              @focus="searchResultsIsOpen = true"
            />

            <!-- Search Results Dropdown -->
            <Transition
              enter-active-class="transition duration-150 ease-out"
              enter-from-class="translate-y-2 opacity-0"
              leave-active-class="transition duration-100 ease-in"
              leave-to-class="translate-y-2 opacity-0"
            >
              <div
                v-if="searchResultsIsOpen && searchQuery.length >= 2"
                class="absolute inset-x-0 top-[calc(100%+12px)] z-50 overflow-hidden rounded-2xl border border-white/[0.1] bg-[#171b28]/95 shadow-2xl shadow-black/60 backdrop-blur-3xl"
              >
                <div v-if="searchResults.length" class="max-h-64 overflow-y-auto p-2">
                  <button
                    v-for="result in searchResults"
                    :key="result.item.id"
                    type="button"
                    class="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left transition hover:bg-primary/20"
                    @click="selectAndPlayGame(result.item)"
                  >
                    <div class="flex h-10 w-10 shrink-0 items-center justify-center">
                      <div v-if="result.item.icon_hash || result.item.icon" class="h-full w-full overflow-hidden rounded-xl ring-1 ring-primary/15">
                        <img
                          :src="`https://cdn.discordapp.com/app-icons/${result.item.id}/${result.item.icon_hash || result.item.icon}.png?size=64`"
                          class="h-full w-full object-cover"
                          :alt="`${result.item.name}`"
                          @error="(e: Event) => { console.warn('Icon failed for', result.item.name, result.item.id); (e.target as HTMLImageElement).style.display='none'; }"
                        />
                      </div>
                      <div v-else class="h-full w-full rounded-xl bg-white/5 flex items-center justify-center">
                        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="text-text-muted/40">
                          <rect x="2" y="6" width="20" height="12" rx="2"/>
                          <path d="M12 12h.01"/>
                        </svg>
                      </div>
                    </div>
                    <div class="min-w-0 flex-1">
                      <div class="truncate text-[15px] font-medium text-text-main">{{ result.item.name }}</div>
                    </div>
                  </button>
                </div>
                <div v-else class="px-4 py-6 text-center text-sm text-text-muted">
                  No matching games found.
                </div>
              </div>
            </Transition>
          </div>

          <!-- Spoofing Toggle -->
          <div class="flex items-center justify-between px-2">
            <div>
              <div class="text-[15px] font-semibold text-text-main">Enable Process Spoofing</div>
            </div>
            <button
              class="relative inline-flex h-6 w-11 items-center rounded-full transition-colors focus:outline-none"
              :class="isSpoofingEnabled ? 'bg-[#3b82f6]' : 'bg-white/10'"
              @click="isSpoofingEnabled = !isSpoofingEnabled"
            >
              <span
                class="inline-block h-4 w-4 transform rounded-full bg-white transition-transform"
                :class="isSpoofingEnabled ? 'translate-x-6' : 'translate-x-1'"
              />
            </button>
          </div>
        </div>

        <!-- Status Card -->
        <div class="w-full max-w-lg mt-2">
          <div class="relative overflow-hidden rounded-[24px] border border-white/[0.06] bg-black/20 p-8 shadow-inner transition-all duration-300">
            <!-- Background gradient for active state -->
            <div v-if="activeGame" class="absolute inset-0 bg-primary/5 opacity-50"></div>

            <div v-if="!activeGame" class="flex flex-col items-center justify-center text-center opacity-60 relative z-10">
              <div class="flex h-12 w-12 items-center justify-center rounded-xl bg-white/5 mb-4">
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5">
                  <path d="M5 3l14 9-14 9V3z" />
                </svg>
              </div>
              <p class="text-sm font-medium text-text-muted">Search and select a game<br/>to get started</p>
            </div>

            <div v-else class="flex flex-col items-center text-center relative z-10">
              <div class="flex h-16 w-16 items-center justify-center mb-4">
                <div v-if="activeGame.icon_hash || activeGame.icon" class="h-full w-full overflow-hidden rounded-2xl bg-black/40 ring-2 ring-primary/30 shadow-[0_0_15px_rgba(142,81,255,0.2)]">
                  <img
                    :src="`https://cdn.discordapp.com/app-icons/${activeGame.id}/${activeGame.icon_hash || activeGame.icon}.png?size=128`"
                    class="h-full w-full object-cover"
                    :alt="activeGame.name"
                    @error="(e: Event) => { console.warn('Active game icon failed for', activeGame?.name); (e.target as HTMLImageElement).style.display='none'; }"
                  />
                </div>
                <div v-else class="h-full w-full rounded-2xl bg-white/5 ring-2 ring-primary/20 flex items-center justify-center">
                  <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="text-text-muted/40">
                    <rect x="2" y="6" width="20" height="12" rx="2"/>
                    <path d="M12 12h.01"/>
                  </svg>
                </div>
              </div>
              
              <h2 class="text-xl font-semibold text-white mb-1">{{ activeGame.name }}</h2>
              <div class="flex items-center gap-2 mb-2">
                <span class="h-2 w-2 rounded-full bg-success shadow-[0_0_8px_rgba(52,211,153,0.8)]" :class="{ 'animate-pulse': isConnecting }"></span>
                <span class="text-sm font-medium" :class="isConnecting ? 'text-text-muted' : 'text-success'">
                  {{ isConnecting ? 'Connecting...' : 'Active' }}
                </span>
              </div>
              <div v-if="isConnectedToRPC && !isConnecting" class="flex items-center gap-2 mb-6">
                <span class="h-2 w-2 rounded-full bg-success shadow-[0_0_8px_rgba(52,211,153,0.8)]"></span>
                <span class="text-sm font-medium text-success font-mono">{{ formattedElapsed }}</span>
              </div>
              <div v-else class="mb-6"></div>

              <button
                class="w-full max-w-[200px] py-2.5 rounded-xl text-sm font-semibold bg-danger/10 text-danger hover:bg-danger hover:text-white border border-danger/20 hover:border-danger/0 transition-all shadow-lg"
                @click="stopPlaying"
              >
                Stop
              </button>
            </div>
          </div>
        </div>

        </div>
      </main>

      <!-- Footer -->
      <footer
        class="relative z-10 flex h-10 shrink-0 items-center justify-between px-6 text-[11px] font-medium tracking-[0.05em] text-text-muted/60"
      >
        <div class="flex items-center gap-1.5">
          <WispLogo :size="12" class="opacity-70" />
          <span>Wisp</span>
        </div>
        <div class="absolute left-1/2 -translate-x-1/2 designed-by-text">Designed by <span class="designed-by-zero">0</span>nerf</div>
        <div>
          <span v-if="allFetchDone">{{ gameDB.length.toLocaleString() }} games available</span>
          <span v-else>Loading catalog...</span>
        </div>
      </footer>
    </div>
  </div>
</template>
