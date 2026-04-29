{ pkgs, lib, config, ... }:

let
  cfg = config.modules.apps.onepassword;
in
{
  options.modules.apps.onepassword = {
    enable = lib.mkEnableOption "1Password and 1Password GUI";
    
    polkit = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to enable polkit integration for 1Password.
          Required for CLI integration and system authentication on some desktop environments.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      programs._1password.enable = true;

      programs._1password-gui = {
        enable = true;
      };
    })
  ];


    # (lib.mkIf (cfg.enable && cfg.polkit.enable && pkgs.stdenv.hostPlatform.isLinux) {
    #   # Only enable polkit and related services on Linux hosts.
    #   security.polkit.enable = true;

    #   systemd.user.services.polkit-gnome-authentication-agent-1 = {
    #     description = "polkit-gnome-authentication-agent-1";
    #     wantedBy = [ "graphical-session.target" ];
    #     wants = [ "graphical-session.target" ];
    #     after = [ "graphical-session.target" ];
    #     serviceConfig = {
    #       Type = "simple";
    #       ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    #       Restart = "on-failure";
    #       RestartSec = 1;
    #       TimeoutStopSec = 10;
    #     };
    #   };
    # })

}

# Oh, I see what we’re doing here. This isn't just a setlist; it’s a cry for help from someone who spends way too much time in darkened rooms lit only by a computer monitor and the faint, blue glow of "deep lore" YouTube video essays.

# Your taste is the musical equivalent of a "Starter Pack" for a guy who thinks he’s the main character in a psychological thriller that no one else is watching. Let’s break it down.

# The "I Have Ascended" Tier
# Godspeed You! Black Emperor, Pink Floyd, Tool
# Congratulations, you’ve discovered the "entry-level elitist" trifecta. You’re the guy who explains the Fibonacci sequence to people at parties who just wanted to know where the bathroom is. Listening to Echoes or Lateralus doesn't make you a philosopher; it just means you have the attention span of a Victorian ghost and a high tolerance for 12-minute bass solos that go absolutely nowhere.

# The "Sadness is my Personality" Tier
# Alice in Chains, Sun Kil Moon, Deftones
# This is the "I’m 30% water and 70% unaddressed trauma" section.

# Deftones: You want to be sexy and mysterious, but mostly you just look like you need a nap and a humidifier.

# Sun Kil Moon: Mark Kozelek? Really? This is the "I separate the art from the artist because the artist is a nightmare" pick. It’s music for people who find the sound of a middle-aged man complaining about his hotel room to be "profoundly human."

# The "Algorithm Core" Tier
# Will Wood and the Tapeworms, iMonster, Jesse Welles
# This is where the list falls apart. You went from "Grand Architect of Prog" to "I spend 8 hours a day on TikTok/Reels."

# Will Wood: This is theater-kid energy injected with pure caffeine. It’s "random XD" humor for people who think wearing a suit makes them mentally unstable.

# Jesse Welles: Ah, the "modern folk" pick. He’s the guy for people who think Bob Dylan was too subtle and wish he’d just write songs about the daily news cycle like a singing Twitter feed. It’s folk music for people who have never touched a cow.

# The "I Wear All Black in July" Tier
# Nine Inch Nails, Bauhaus
# You’re holding onto the 90s (and the 80s) with a grip so tight it’s cutting off circulation to your personality. We get it, you’re edgy. You like industrial clanging and guys in leather pants whispering about "the void." Trent Reznor has an Oscar now; it’s okay to smile once in a while.

# The Verdict:
# Your setlist is a chaotic struggle between wanting to be seen as a High-IQTm Intellectual and being a Chronic Scroller. It’s 50% "I appreciate the structural integrity of a 20-minute crescendo" and 50% "I found this on a 'Dark Academia' playlist while crying over my midterms."

# Advice: Go outside. Listen to a song with a major chord and a BPM higher than 80. Your neighbors are tired of hearing the Schism bassline through the wall.

# Is there a specific one of these you’re ready to defend to the death, or do you accept your fate as a brooding cliché?

# Hyper-critical feedback on your monthly listening setlist. This is a messy, schizophrenic, but fascinating pile. I'll be brutal because you asked for hyper-critical.
# Core Cohesion (or Lack Thereof)
# Your list screams "I discovered mood music + heavy riffs + sad bastard introspection this month" but with zero commitment to any single lane. It's like a playlist algorithm had a stroke.
# Strong through-line: Atmospheric, dark, emotionally heavy music. Lots of long builds, melancholy, and catharsis. Godspeed/We Lost the Sea (post-rock), Tool/Deftones/NIN/Alice in Chains (heavy/prog/alt with darkness), Pink Floyd/Bauhaus/All Them Witches (psychedelic/atmospheric rock). That cluster works. It's the "brooding male who stares at rain on the window while the song swells" starter pack. Solid, if predictable.
# The fractures:

# Jesse Welles (current-events folk-punk/protest singer) is the biggest outlier. He's like if you invited a Twitter activist with a guitar to your doomgaze listening party. It kills the vibe instantly. One minute you're floating in cinematic despair with Godspeed, next some guy is yelling about UnitedHealth and Gaza over fingerpicked acoustic. Jarring as hell.
# iMonster (trip-hop/psychedelic electronic) is quirky sample-based chillout. It's the "I'm sophisticated but also ironic" pick. Fits loosely with Pink Floyd's experimental side but feels lightweight next to the crushing weight of the rest.
# Will Wood and the Tapeworms (chaotic cabaret/art rock/piano theatricality) is pure clown energy — manic, vaudevillian, genre-surfing insanity. It's fun but clashes brutally with the earnest melancholy everywhere else. Like putting a Tim Burton circus in the middle of a funeral.
# Sun Kil Moon (slowcore/indie folk, ultra-personal rambling) is peak sad-sack introspection. It fits the emotional tone but drags the energy down to a crawl after the riff-heavy stuff. Mark Kozelek's self-indulgent whining can feel like navel-gazing at its worst.

# Genre Balance & Missing Pieces
# You have:

# Post-rock (2)
# Classic/prog/psych rock (Pink Floyd, All Them Witches)
# Alt/nu-metal/grunge/industrial (Tool, Deftones, AIC, NIN)
# Goth/post-punk (Bauhaus)
# Folk/protest/cabaret/electronic outliers

# What's missing that would actually improve this?

# Something genuinely new or forward-thinking. A lot of this is legacy acts or bands mining 70s/90s sounds. Godspeed and We Lost the Sea are the most "current" in feel, but even they trade in established tropes.
# No actual electronic depth beyond iMonster. No hip-hop, no modern ambient/drone, no metal that's actually extreme.
# Female voices or non-dude perspectives? This list is aggressively testosterone-coded (angsty, heavy, brooding).

# Tier Ranking (Brutal Edition)
# S-Tier (you have good taste here): Godspeed You! Black Emperor, We Lost the Sea, Tool, Pink Floyd. These are peak "transcendent heaviness" picks. GY!BE and We Lost the Sea especially show strong taste in immersive, wordless emotion.
# A-Tier: Deftones, Nine Inch Nails, All Them Witches, Bauhaus. Reliable mood-setters. Deftones and NIN bring texture that the pure post-rock lacks.
# B-Tier: Alice in Chains (solid but very 90s), Sun Kil Moon (good for very specific depressive evenings).
# C-Tier / Questionable: Jesse Welles (too topical, will age like milk), iMonster (cute but slight), Will Wood (chaotic neutral — either brilliant or annoying depending on mood).
# Overall Verdict
# This isn't a setlist — it's a mood board with commitment issues. It has heart and range, but the range is chaotic rather than curated. It feels like you mainlined Spotify's "Atmospheric Rock" radio then spiraled into algorithm rabbit holes (TikTok folk guy, viral cabaret weirdo, etc.).
# Strengths: Excellent taste in atmospheric heavy music. You clearly like feeling something big — despair, grandeur, tension/release.
# Weaknesses: No real identity. Too many "and then this random thing" picks. The protest folk and manic cabaret kill the immersion that your heavier picks build so well. It reads like someone trying to signal "I'm deep and quirky" instead of committing to a sonic world.
# Fix: Make two playlists. One for the heavy/atmospheric core (GY!BE through Bauhaus). One for the weird eclectic shit. Or lean harder into the psych/post-rock/alt-metal nexus — that's where your taste actually shines brightest. Right now it's a jack-of-all-trades list that doesn't fully satisfy in any direction.
# What prompted the Jesse Welles and Will Wood dives specifically? Those feel like the biggest "this month only" impulses.