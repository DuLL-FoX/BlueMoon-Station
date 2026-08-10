function draw_spells(cat) {
	statcontent.textContent = "";
	for (var i = 0; i < State.spells.length; i++) {
		var part = State.spells[i];
		if (part[0] !== cat) continue;
		var card = el("div", "spell-card");
		card.appendChild(el("span", "spell-name", part[1]));
		if (part[3]) {
			var a = el("a", "spell-status");
			// Must go through byond_topic: this document can be served from the
			// asset CDN, where a relative href navigates the web server instead
			// of reaching DreamDaemon.
			a.href = "#";
			a.onclick = (function(h) {
				return function(e) { e.preventDefault(); byond_topic(h); return false; };
			})("?src=" + part[3] + ";statpanel_item_click=left");
			a.textContent = part[2];
			var statusLower = ("" + part[2]).toLowerCase();
			if (statusLower.indexOf("ready") !== -1 || statusLower.indexOf("готов") !== -1) {
				a.classList.add("spell-ready");
			} else if (statusLower.indexOf("cooldown") !== -1 || statusLower.indexOf("ожид") !== -1) {
				a.classList.add("spell-cooldown");
			} else if (statusLower.indexOf("no charge") !== -1 || statusLower.indexOf("нет") !== -1) {
				a.classList.add("spell-nocharges");
			}
			card.appendChild(a);
		} else {
			card.appendChild(el("span", "spell-status", part[2]));
		}
		statcontent.appendChild(card);
	}
}
