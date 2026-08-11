import { createGlobalState } from '@vueuse/core'
import { ShallowRef, shallowRef } from 'vue'

export interface AppLogObject {
    type: 'info' | 'error' | 'warning' | 'debug';
    message: string;
    timestamp: Date;
}
export interface UseGlobalStateReturn {
    logs: ShallowRef<AppLogObject[]>,
    addLog: {
        (type: 'info' | 'error' | 'warning' | 'debug', newLog: string): void;
        (newLog: string): void;
    };
    clearLogs: () => void,
}
export const useGlobalState = createGlobalState(
  () => {
    const logs = shallowRef<AppLogObject[]>([])

    function addLog(type: string | 'info' | 'error' | 'warning' | 'debug' , newLog?: string) {
      if (!newLog) {
        newLog = type;
        type = 'info';
      }
      const formattedLog = `${newLog}`;
      logs.value.push({ type: type as 'info' | 'error' | 'warning' | 'debug', message: formattedLog, timestamp: new Date() });
    }

    function clearLogs() {
      logs.value = []
    }

    return {
        logs,
        addLog,
        clearLogs
    } as UseGlobalStateReturn
  }
)
