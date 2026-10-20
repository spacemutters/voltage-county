// POST /api/design: a new car from a player's description (Phase 11 AI Car Designer). Called only by the game
// server (DesignerService) with the shared secret in x-api-key. The pipeline lives in lib/handler.ts.
import { serve } from "../lib/handler.ts";

const handle = serve("design");

export function POST(request: Request): Promise<Response> {
	return handle(request);
}

export function GET(request: Request): Promise<Response> {
	return handle(request);
}
