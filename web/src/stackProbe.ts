import { STACK_HEADER } from "./api";

/**
 * Asks the server that served this page which stack it is, so the badge is right before any API
 * call. It reads the X-ShipTrack-Stack header of a GET of the UI's own base path, which both
 * stacks answer with the header whatever the status, and which the load balancer routes with the
 * page. Returns null when there is no answer.
 */
export async function probeStack(signal?: AbortSignal): Promise<string | null> {
  try {
    const response = await fetch(import.meta.env.BASE_URL, { cache: "no-store", signal });
    void response.body?.cancel();
    return response.headers.get(STACK_HEADER);
  } catch {
    return null;
  }
}
