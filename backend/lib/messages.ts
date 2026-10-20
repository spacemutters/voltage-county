// Every message a player can see from the backend. Short, friendly, plain words for a general audience that
// includes kids; never technical. The game filters them with TextService before showing them anyway.
// Read by: limits.ts, handler.ts.
export const REFUSALS = {
	off: "The design studio is taking a short break. Your credits are safe. Try again later!",
	busy: "The design studio is really busy right now. Your credits are safe. Try again in a little while!",
	playerLimit: "You've designed a lot today! Take a short break and try again later. Your credits are safe.",
	tooShort: "Tell us a bit more about the car you want, like its shape, color or style.",
	blocked: "We can't design that one. Try describing a different car!",
	brand: "We can only make original cars, not real brands or famous movie cars. Try describing the style you like instead!",
	safety: "We can't design that one. Try describing a different car!",
	error: "Something went wrong while designing your car. Your credits are safe. Please try again.",
	timeout: "The designer took too long to answer. Your credits are safe. Please try again.",
	badRequest: "That request didn't look right. Please try again.",
	kitVersion: "The design studio is being updated. Your credits are safe. Try again in a few minutes!",
	notAllowed: "Not allowed.",
	method: "Use POST.",
	unavailable: "The design studio isn't set up yet. Your credits are safe.",
};
