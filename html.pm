package html;

our $phont = 'phont4';
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

our $header = qq{
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
  
  <table width=1280 cellpadding=0 cellspacing=0>
    <tr>
      <td style='font-size: 40px'>[
  
        <a href="/"><img class="button" height="24" width="64" src="https://fontasy.io/$phont.png?txt=rand&dim=8&chop=0"/></a>
        | <a href="/new"><img class="button" height="24" width="48" src="https://fontasy.io/$phont.png?txt=new&dim=8&chop=0"/></a>
        | <img class="redbutton" height="24" width="48" src="https://fontasy.io/$phont.png?txt=top&dim=8&chop=0" onclick="alert('returning soon')"/>
        | <img class="redbutton" height="24" width="96" src="https://fontasy.io/$phont.png?txt=search&dim=8&chop=0" onclick="alert('coming soon')"/>
  
      ]</td>
  
      <td align="right" height="70">
        <div id="userbar" style="display: none">
          <table>
            <tr>
              <td style="font-size: 40px">
                [
                  <a href="/logout"><img class="button" height="24" width="96" src="https://fontasy.io/$phont.png?txt=logout&dim=16"/></a>
                ]
  
                <!--
                <a id="userlink"><img align="center" style="border: 3px solid blue"  width=64 height=64></a>
                -->
              </td>
            </tr>
          </table>
        </div>
        <div id="loginbar" style="display: block">
          <table>
            <tr>
              <td rowspan="2" valign="center" style="font-size: 40px">
                [
              </td>
  
              <td align="right"><img height="24" width="48" src="https://fontasy.io/$phont.png?txt=nom&dim=8"/></script></td>
              <td>
                <input id="nomlogin" type="text" style="font-family: monospace; font-size: medium" size=32 maxlength=32 onClick="this.value=''" value=""/>
              </td>

              <td width="8"></td>

              <td rowspan="2" valign="center" style="font-size: 40px">
                <img class="redbutton" height="24" width="80" src="https://fontasy.io/$phont.png?txt=login&dim=8&chop=0" onclick="alert('returning soon')"/>
                ]
              </td>
            </tr>
            <tr>
              <td align="right">
                <img height="24" width="64" src="https://fontasy.io/$phont.png?txt=pass&dim=8"/>
              </td>
              <td>
                <input id="nompass" type="password" style="font-family: monospace; font-size: medium" size=32 maxlength=32 />
              </td>
            </tr>
          </table>
        </div>
      </td>
    </tr>
  
  
    <tr>
      <td colspan="2">
        <div style="width: 1280px; height: 4px; background-color: #444444"></div>
      </td>
    </tr>
    <tr>
      <td align="left"> 
        <table><tr>
          <td valign="bottom"><img width="288" height="48" src="https://fontasy.io/$phont.png?txt=Peaple.IO&dim=16"></td>
          <td valign="bottom" width="4"></td>
          <td valign="bottom"><img width="64" height="24" src="https://fontasy.io/$phont.png?txt=v1.2&dim=8"></td>
        </tr></table>
      </td>
      <td valign="top" align="right">
        <a href="https://makemoresoftware.com/">
          <img src="https://fontasy.io/$phont.png?txt=a+MakeMore+Software+product&dim=8"/>
        </a>
          <br/>
        <a href="https://makemoresoftware.com/">
          <img src="https://fontasy.io/$phont.png?txt=https://makemoresoftware.com/&dim=8"/>
        </a>
      </td>
    </tr>
  
    <tr>
      <td colspan="2">
        <div style="width: 1280px; height: 4px; background-color: #444444"></div>
      </td>
    </tr>
  </table>
};

sub subhead {
  my $nom = shift;

  qq{
    <table width=1280 cellpadding=0 cellspacing=0>
      <tr height=8></tr>
    
      <tr>
        <td style='font-size: 40px'>[
          <a href="/$nom"><img id="buttonwall" height="24" width="64" class="button" src="https://fontasy.io/$phont.png?txt=wall&dim=8&chop=0"/></a> |
          <a href="/$nom/fam"><img id="buttonfam" height="24" width="48" class="button" src="https://fontasy.io/$phont.png?txt=fam&dim=8&chop=0"/></a> |
          <a href="/$nom/frens"><img id="buttonfrens" height="24" width="80" class="button" src="https://fontasy.io/$phont.png?txt=frens&dim=8&chop=0"/></a> |
          <a href="/$nom/xform"><img id="buttonxform" height="24" width="80" class="button" src="https://fontasy.io/$phont.png?txt=xform&dim=8&chop=0"/></a> |
          <a href="/$nom/enc"><img id="buttonenc" height="24" width="48" class="button" src="https://fontasy.io/$phont.png?txt=enc&dim=8&chop=0"/></a> |
          <a href="/$nom/grid"><img id="buttongrid" height="24" width="64" class="button" src="https://fontasy.io/$phont.png?txt=grid&dim=8&chop=0"/></a> |
          <a href="/$nom/mem"><img id="buttonmem" height="24" width="48" class="button" src="https://fontasy.io/$phont.png?txt=mem&dim=8&chop=0"/></a> |
          <a href="/$nom/gogh"><img id="buttongogh" height="24" width="64" class="button" src="https://fontasy.io/$phont.png?txt=gogh&dim=8&chop=0"/></a> |
          <a href="https://www.facebook.com/groups/434429760588423/"><img id="buttonfb" height="24" width="32" class="button" src="https://fontasy.io/$phont.png?txt=fb&dim=8&chop=0"/></a> |
          <a href="mailto:dan\@makemoresoftware.com?subject=$nom"><img id="buttonnote" class="button" height="24" width="64" src="https://fontasy.io/$phont.png?txt=note&dim=8&chop=0"/></a> |
          <img id="buttonbuy" class="redbutton" height="24" width="48" src="https://fontasy.io/$phont.png?txt=buy&dim=8&chop=0" onclick="alert('coming soon')"/>
        ]</td>
    
        <td align="right"><div id='meepdiv' style="display: none; font-size: 40px">[
          <img class="button" src="https://fontasy.io/$phont.png?txt=befren&dim=8&chop=0"/></a>
        ]</div></td>
    
      </tr>
    </table>
    <br/>
    
    
    <script>
    (function() {
      var ll = window.location.pathname + "";
      var fl = ll.lastIndexOf('/');
      if (fl < 0) { return; }
      var func = ll.substr(fl + 1);
      if (func == '$nom') { func = 'wall'; }
      var elem = document.getElementById('button' + func);
      elem.style = 'outline: 3px solid #00ff00';
    })();
    </script>
  }
}
  
1
