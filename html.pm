package html;

our $phont = 'titulus';
our $fontasy = $ENV{PEAPLE_FONTASY} // '$fontasy';
# our $phont = 'chamscrabold';
# our $phont = 'asdf';

our $google = qq{
  <script async src="https://www.googletagmanager.com/gtag/js?id=UA-151395366-1"></script>
  <script>
    window.dataLayer = window.dataLayer || [];
    function gtag(){dataLayer.push(arguments);}
    gtag('js', new Date());

    gtag('config', 'UA-151395366-1');
  </script>
};

our $user = '';   # logged-in nom (peaple.pl sets it from the session cookie, then rebuilds $header)

sub header {
  my $u = shift // '';
  my ($ubar, $lbar) = $u ne '' ? ('block', 'none') : ('none', 'block');
  # font selector: each name drawn in its own phont; the choice is a cookie peaple.pl reads into $phont
  my $sel = join(" |\n        ", map {
    my $w = 16 * length($_);
    my $cls = $_ eq $phont ? "style='outline: 3px solid #00ff00; cursor: pointer'" : "class='button'";
    qq{<img $cls height="24" width="$w" src="$fontasy$_.png?txt=$_&dim=8&chop=0" title="$_" onclick="setphont('$_')"/>}
  } qw(mork they ahoy titulus));
  my $uimg = $u ne '' ? qq{<a id="userlink" href="/$u"><img style="display: block; border: 3px solid blue" src="/$u.png?dim=128&nostamp=1" title="$u" width=64 height=64></a>} : '';
  qq{
  $google

  <style type="text/css">
    .button {
      outline: 3px solid blue;
      cursor: pointer
    }
    .redbutton {
      outline: 3px solid red;
      cursor: pointer
    }
  </style>
  
  <script>
    // login as makemore did it: the first login to a nom accepts any password and sets it
    window.usernom = "$u";
    function setphont(p) {
      document.cookie = 'phont=' + p + '; path=/; max-age=31536000; SameSite=Lax';
      location.reload();
    }
    function badpass() {
      var b = document.getElementById('headlogin');
      b.style.outline = "3px solid red";
      document.getElementById('nompass').value = '';
      window.setTimeout(function() { b.style.outline = "3px solid blue"; }, 1000);
    }
    function clicklogin() {
      var n = document.getElementById('nomlogin').value.toLowerCase().replace(/\\s+/g, '');
      var p = document.getElementById('nompass').value;
      if (!n || !p) { badpass(); return; }
      document.getElementById('headlogin').style.outline = "3px solid yellow";
      var i = new XMLHttpRequest;
      i.open('POST', '/login.json');
      i.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
      i.onload = function() {
        var ok = false;
        try { ok = this.status == 200 && JSON.parse(this.responseText).ok; } catch (e) { }
        if (ok) { location.reload(); } else { badpass(); }
      };
      i.onerror = badpass;
      i.send('nom=' + encodeURIComponent(n) + '&pass=' + encodeURIComponent(p));
    }
  </script>

  <table width=1280 cellpadding=0 cellspacing=0>
    <tr>
      <td style='font-size: 40px; white-space: nowrap'>[
  
        <a href="/"><img class="button" height="24" width="64" src="$fontasy$phont.png?txt=rand&dim=8&chop=0"/></a>
        | <a href="/new"><img class="button" height="24" width="48" src="$fontasy$phont.png?txt=new&dim=8&chop=0"/></a>
        | <a href="/top"><img id="headtop" class="button" height="24" width="48" src="$fontasy$phont.png?txt=top&dim=8&chop=0"/></a>
        | <a href="/nooz"><img id="headnooz" class="button" height="24" width="64" src="$fontasy$phont.png?txt=nooz&dim=8&chop=0"/></a>
  
      ]</td>

      <td align="center" style='font-size: 40px; white-space: nowrap; padding-left: 24px'>[
        $sel
      ]</td>
  
      <td align="right" height="70">
        <div id="userbar" style="display: $ubar">
          <table cellpadding=0 cellspacing=0>
            <tr>
              <td valign="middle" style="font-size: 40px; white-space: nowrap">[
                <a href="/$u/thotz"><img id="buttonthotz" class="button" height="24" width="80" src="$fontasy$phont.png?txt=thotz&dim=8&chop=0" title="your system prompt"/></a> |
                <a href="/logout"><img class="button" height="24" width="96" src="$fontasy$phont.png?txt=logout&dim=8&chop=0"/></a>
              ]</td>
              <td width="8"></td>
              <td valign="middle">$uimg</td>
            </tr>
          </table>
        </div>
        <div id="loginbar" style="display: $lbar">
          <table>
            <tr>
              <td rowspan="2" valign="center" style="font-size: 40px">
                [
              </td>
  
              <td align="right"><img height="24" width="48" src="$fontasy$phont.png?txt=nom&dim=8"/></script></td>
              <td>
                <input id="nomlogin" type="text" style="font-family: monospace; font-size: medium" size=16 maxlength=32 onClick="this.value=''" value=""/>
              </td>

              <td width="8"></td>

              <td rowspan="2" valign="center" style="font-size: 40px">
                <img id="headlogin" class="button" height="24" width="80" src="$fontasy$phont.png?txt=login&dim=8&chop=0" onclick="clicklogin()"/>
                ]
              </td>
            </tr>
            <tr>
              <td align="right">
                <img height="24" width="64" src="$fontasy$phont.png?txt=pass&dim=8"/>
              </td>
              <td>
                <input id="nompass" type="password" onkeypress="if (event.which == 13) { clicklogin(); }" style="font-family: monospace; font-size: medium" size=16 maxlength=32 />
              </td>
            </tr>
          </table>
        </div>
      </td>
    </tr>
  
  
    <tr>
      <td colspan="3">
        <div style="width: 1280px; height: 4px; background-color: #444444"></div>
      </td>
    </tr>
    <tr>
      <td align="left"> 
        <table><tr>
          <td valign="bottom"><img width="288" height="48" src="$fontasy$phont.png?txt=Peaple.IO&dim=16"></td>
          <td valign="bottom" width="4"></td>
          <td valign="bottom"><img width="96" height="24" src="$fontasy$phont.png?txt=v2.0.1&dim=8"></td>
        </tr></table>
      </td>
      <td colspan="2" valign="top" align="right">
        <a href="https://makemoresoftware.com/">
          <img src="$fontasy$phont.png?txt=a+MakeMore+Software+product&dim=8"/>
        </a>
          <br/>
        <a href="https://makemoresoftware.com/">
          <img src="$fontasy$phont.png?txt=https://makemoresoftware.com/&dim=8"/>
        </a>
      </td>
    </tr>
  
    <tr>
      <td colspan="3">
        <div style="width: 1280px; height: 4px; background-color: #444444"></div>
      </td>
    </tr>
  </table>
  }
}

our $header = header('');

sub subhead {
  my $nom = shift;
  my $meep = ($user ne '' && $user ne $nom) ? 'block' : 'none';

  qq{
    <table width=1280 cellpadding=0 cellspacing=0>
      <tr height=8></tr>
    
      <tr>
        <td style='font-size: 40px'>[
          <a href="/$nom"><img id="buttonwall" height="24" width="64" class="button" src="$fontasy$phont.png?txt=wall&dim=8&chop=0"/></a> |
          <a href="/$nom/chat"><img id="buttonchat" height="24" width="64" class="button" src="$fontasy$phont.png?txt=chat&dim=8&chop=0"/></a> |
          <a href="/$nom/fam"><img id="buttonfam" height="24" width="48" class="button" src="$fontasy$phont.png?txt=fam&dim=8&chop=0"/></a> |
          <a href="/$nom/frens"><img id="buttonfrens" height="24" width="80" class="button" src="$fontasy$phont.png?txt=frens&dim=8&chop=0"/></a> |
          <a href="/$nom/xform"><img id="buttonxform" height="24" width="80" class="button" src="$fontasy$phont.png?txt=xform&dim=8&chop=0"/></a> |
          <a href="/$nom/enc"><img id="buttonenc" height="24" width="48" class="button" src="$fontasy$phont.png?txt=enc&dim=8&chop=0"/></a> |
          <a href="/$nom/grid"><img id="buttongrid" height="24" width="64" class="button" src="$fontasy$phont.png?txt=grid&dim=8&chop=0"/></a> |
          <a href="/$nom/mem"><img id="buttonmem" height="24" width="48" class="button" src="$fontasy$phont.png?txt=mem&dim=8&chop=0"/></a> |
          <a href="https://www.facebook.com/groups/434429760588423/"><img id="buttonfb" height="24" width="32" class="button" src="$fontasy$phont.png?txt=fb&dim=8&chop=0"/></a> |
          <a href="mailto:dan\@makemoresoftware.com?subject=$nom"><img id="buttonnote" class="button" height="24" width="64" src="$fontasy$phont.png?txt=note&dim=8&chop=0"/></a> |
          <a href="https://www.linkedin.com/in/dan-brumleve/"><img id="buttonbuy" class="button" height="24" width="48" src="$fontasy$phont.png?txt=buy&dim=8&chop=0"/></a>
        ]</td>
    
        <td align="right"><div id='meepdiv' style="display: $meep; font-size: 40px">[
          <img class="button" height="24" width="96" src="$fontasy$phont.png?txt=befren&dim=8&chop=0" onclick="befren()"/>
        ]</div></td>
    
      </tr>
    </table>
    <br/>
    
    
    <script>
    function befren() {   // the logged-in user and this parson become frens (addfren is mutual)
      var i = new XMLHttpRequest;
      i.open('POST', '/$user/addfren.json');
      i.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
      i.onload = function() { location = '/$user/frens'; };
      i.send('fren=$nom');
    }
    (function() {
      var ll = window.location.pathname + "";
      var fl = ll.lastIndexOf('/');
      if (fl < 0) { return; }
      var func = ll.substr(fl + 1);
      if (func == '$nom') { func = 'wall'; }
      var elem = document.getElementById('button' + func);
      if (elem) { elem.style = 'outline: 3px solid #00ff00'; }
    })();
    </script>
  }
}
  
1
