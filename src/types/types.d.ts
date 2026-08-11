export interface GameExecutable {
  is_launcher: boolean;
  name: string;
  os: string;
  arguments?: string;
  filename?: string;
  path?: string;
  segments?: number;
  is_running?: boolean;
  is_installed?: boolean;
}

export interface Game {
  uid?: string;
  id: string;
  name: string;
  icon?: string;
  icon_hash?: string;
  cover_image_hash?: string;
  executables: GameExecutable[];
  aliases?: string[];
  themes?: string[];
  is_running?: boolean;
  is_installed?: boolean;
}
