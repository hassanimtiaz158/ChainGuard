/**
 * Typed client for the ChainGuard API.
 *
 * The base URL comes from the environment only (`NEXT_PUBLIC_API_URL`). The API
 * itself always talks to the bundled local Anvil chain; the RPC URL is never
 * something the browser can influence.
 */

export const API_BASE_URL = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000";

export interface HealthResponse {
  status: "ok" | "degraded";
  chain: {
    connected: boolean;
    /** ChainGuard refuses to serve runs unless this is 31337. */
    chain_id: number | null;
  };
  database: { connected: boolean };
  redis: { connected: boolean };
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE_URL}${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...init?.headers },
  });

  if (!response.ok) {
    throw new ApiError(`${init?.method ?? "GET"} ${path} failed: ${response.status}`, response.status);
  }

  return (await response.json()) as T;
}

export const api = {
  health: () => request<HealthResponse>("/api/health"),
};