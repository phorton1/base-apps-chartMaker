#!/usr/bin/perl
# Ask ESRI what resolution it actually holds at a set of points.
# Layer 0 ('World Imagery') is the authoritative answer; the rest are
# per-resolution metadata layers that repeat it.
use strict;
use warnings;
use JSON::PP;

my $URL = "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/identify";

my @PTS = (
	[ 'Miami',          25.7617,  -80.1918 ],
	[ 'New York City',  40.7128,  -74.0060 ],
	[ 'SanBlas island',  9.6000,  -78.6600 ],
	[ 'Bocas Popa00',    9.334083,-82.242050 ],
	[ 'Bocas town',      9.3400,  -82.2400 ],
	[ 'Bocas NW',        9.4400,  -82.3600 ],
	[ 'Bocas SW',        8.9500,  -82.2500 ],
	[ 'Bocas E islet',   9.1000,  -81.5500 ],
	[ 'Bocas open sea',  9.4500,  -82.0000 ],
);

printf("%-16s %-8s %-6s %-9s %-12s %s\n",
	'POINT','RES(M)','MAXLV','DATE','DESCRIPTION','SOURCE_INFO');
print '-' x 78, "\n";

for my $p (@PTS)
{
	my ($name,$lat,$lon) = @$p;
	my $ext = sprintf("%.4f,%.4f,%.4f,%.4f",$lon-0.01,$lat-0.01,$lon+0.01,$lat+0.01);
	my $cmd = "curl -s -m 30 -G \"$URL\"".
		" --data-urlencode \"geometry=$lon,$lat\"".
		" --data-urlencode \"geometryType=esriGeometryPoint\"".
		" --data-urlencode \"sr=4326\"".
		" --data-urlencode \"layers=all\"".
		" --data-urlencode \"tolerance=1\"".
		" --data-urlencode \"mapExtent=$ext\"".
		" --data-urlencode \"imageDisplay=400,400,96\"".
		" --data-urlencode \"returnGeometry=false\"".
		" --data-urlencode \"f=json\"";

	my $out = `$cmd`;
	my $j = eval { JSON::PP->new->decode($out) };
	if (!$j || !$j->{results})
	{
		printf("%-16s  -- no answer --\n",$name);
		next;
	}

	my ($top) = grep { $_->{layerId} == 0 } @{$j->{results}};
	if (!$top)
	{
		printf("%-16s  -- nothing at layer 0 --\n",$name);
		next;
	}
	my $a = $top->{attributes};
	printf("%-16s %-8s %-6s %-9s %-12s %s\n",
		$name,
		$a->{'RESOLUTION (M)'} // '?',
		$a->{MaxMapLevel} // '?',
		$a->{'DATE (YYYYMMDD)'} // '-',
		substr($a->{DESCRIPTION} // '-',0,12),
		$a->{SOURCE_INFO} // '-');
}
