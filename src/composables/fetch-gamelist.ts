import type { Game } from '@/types/types';
import { ref } from 'vue';
import { invoke } from '@tauri-apps/api/core';
import { useGlobalState } from './app-state';
import { tryOnMounted } from '@vueuse/core';

export function useFetchGameList() {
    const { addLog } = useGlobalState();

    const gameDB = ref<Game[]>([]);
    const isLoading = ref(false);
    const allFetchDone = ref(false);

    function isValidGameList(data: unknown): data is Game[] {
        return Array.isArray(data) && data.length > 0 && typeof data[0] === 'object' && data[0] !== null && 'name' in data[0] && 'id' in data[0];
    }

    async function fetchGameList() {
        isLoading.value = true;
        allFetchDone.value = false;

        let parsedGames: Game[] = [];

        try {
            addLog('info', 'Fetching game list from GitHub mirror...');
            const rawText: string = await invoke('fetch_gamelist_gh_mirror');
            const parsed = JSON.parse(rawText);
            if (isValidGameList(parsed)) {
                parsedGames = parsed;
                addLog('info', `Loaded ${parsedGames.length} games from mirror.`);
            }
        } catch {
            addLog('warning', 'Mirror fetch failed, trying Discord...');
        }

        if (parsedGames.length === 0) {
            try {
                addLog('info', 'Fetching game list from Discord...');
                const rawText: string = await invoke('fetch_gamelist_from_discord');
                const parsed = JSON.parse(rawText);
                if (isValidGameList(parsed)) {
                    parsedGames = parsed;
                    addLog('info', `Loaded ${parsedGames.length} games from Discord.`);
                }
            } catch (e: any) {
                addLog('error', `Discord catalog fetch failed: ${e?.message || e}`);
            }
        }

        gameDB.value = parsedGames;
        isLoading.value = false;

        setTimeout(() => {
            allFetchDone.value = true;
        }, 500);
    }

    tryOnMounted(async () => {
        await fetchGameList();
    });

    return {
        gameDB,
        fetchGameList,
        isLoading,
        allFetchDone,
    };
}

