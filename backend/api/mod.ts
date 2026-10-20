// POST /api/mod: an AI mod for a car the player owns (Phase 11). Called only by the game server (DesignerService)
// with the shared secret in x-api-key. The pipeline lives in lib/handler.ts.
import { serve } from "../lib/handler.ts";

const handle = serve("mod");

export function POST(request: Request): Promise<Response> {
	return handle(request);
}

export function GET(request: Request): Promise<Response> {
	return handle(request);
}
