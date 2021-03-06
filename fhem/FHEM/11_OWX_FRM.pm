########################################################################################
#
# OWX_FRM.pm
#
# FHEM module providing hardware dependent functions for the FRM interface of OWX
#
# Norbert Truchsess
#
# $Id: 11_OWX_FRM.pm 2013-03 - ntruchsess $
#
########################################################################################
#
# Provides the following methods for OWX
#
# Define
# Init
# Verify #TODO refactor Verify...
# search
# alarms
# execute
#
########################################################################################

package OWX_FRM;

use strict;
use warnings;

use Device::Firmata::Constants qw/ :all /;
use Time::HiRes qw(gettimeofday tv_interval);

sub new() {
	my ($class) = @_;

	return bless {
		interface => "firmata",
	    #-- module version
		version => 4.0
	}, $class;
}

sub Define($$) {
	my ($self,$hash,$def) = @_;
	$self->{name} = $hash->{NAME};
	$self->{hash} = $hash;

 	if (defined $main::modules{FRM}) {
  	main::AssignIoPort($hash);
  	my @a = split("[ \t][ \t]*", $def);
  	my $u = "wrong syntax: define <name> FRM_XXX pin";
		return $u unless int(@a) > 0;
		$self->{pin} = $a[2];
		$self->{id} = 0;
		return undef;
	} else {
	  my $ret = "module FRM not yet loaded, please define an FRM device first."; 
	  main::Log(1,$ret);
	  return $ret;
	}
}

########################################################################################
# 
# Init - Initialize the 1-wire device
#
# Parameter hash = hash of bus master
#
# Return 1 or Errormessage : not OK
#        0 or undef : OK
#
########################################################################################

sub Init($)
{
	my ($self,$hash) = @_;
	
	my $pin = $self->{pin};
	my $ret = main::FRM_Init_Pin_Client($hash,[$pin],PIN_ONEWIRE);
	return $ret if (defined $ret);
	my $firmata = $hash->{IODev}->{FirmataDevice};
	$firmata->observe_onewire($pin,\&FRM_OWX_observer,$self);
	$self->{devs} = [];
	if ( main::AttrVal($hash->{NAME},"buspower","") eq "parasitic" ) {
		$firmata->onewire_config($pin,1);
	}
	$firmata->onewire_search($pin);
	return undef;
}

sub Disconnect($)
{
	my ($hash) = @_;
	$hash->{STATE} = "disconnected";
};

sub FRM_OWX_observer
{
	my ( $data,$self ) = @_;
	my $command = $data->{command};
	COMMAND_HANDLER: {
		$command eq "READ_REPLY" and do {
			my $id = $data->{id};
			my $request = (defined $id) ? $self->{requests}->{$id} : undef;
			unless (defined $request) {
				return unless (defined $data->{device});
				my $owx_device = FRM_OWX_firmata_to_device($data->{device});
				my %requests = %{$self->{requests}};
				foreach my $key (keys %requests) {
					if ($requests{$key}->{device} eq $owx_device) {
						$request = $requests{$key};
						$id = $key;
						last;
					};
				};
			};
			return unless (defined $request);
			my $owx_data = pack "C*",@{$data->{data}};
			my $owx_device = $request->{device};
			my $context = $request->{context};
			my $data = pack "C*",@{$request->{command}->{'write'}} if (defined $request->{command}->{'write'});
			main::OWX_AfterExecute( $self->{hash},$context,1,$request->{'reset'}, $owx_device, $data, $request->{'read'}, $owx_data );
			delete $self->{requests}->{$id};
			last;			
		};
		($command eq "SEARCH_REPLY" or $command eq "SEARCH_ALARMS_REPLY") and do {
			my @owx_devices = ();
			foreach my $device (@{$data->{devices}}) {
				push @owx_devices, FRM_OWX_firmata_to_device($device);
			};
			if ($command eq "SEARCH_REPLY") {
				$self->{devs} = \@owx_devices;
				main::OWX_AfterSearch($self->{hash},\@owx_devices);
			} else {
				$self->{alarmdevs} = \@owx_devices;
				main::OWX_AfterAlarms($self->{hash},\@owx_devices);
			};
			last;
		};
	};
};

########### functions implementing interface to OWX ##########

sub FRM_OWX_device_to_firmata
{
	my @device;
	foreach my $hbyte (unpack "A2xA2A2A2A2A2A2xA2", shift) {
		push @device, hex $hbyte;
	}
	return {
		family => shift @device,
		crc => pop @device,
		identity => \@device,
	}
}

sub FRM_OWX_firmata_to_device
{
	my $device = shift;
	return sprintf ("%02X.%02X%02X%02X%02X%02X%02X.%02X",$device->{family},@{$device->{identity}},$device->{crc});
}

########################################################################################
#
# asynchronous methods search, alarms and execute
#
########################################################################################

sub search($) {
	my ($self,$hash) = @_;
	my $success = undef;
	eval {
  	if (my $firmata = main::FRM_Client_FirmataDevice($hash) and my $pin = $self->{pin} ) {
			$firmata->onewire_search($pin);
			$success = 1;
		};
	};
	if ($@) {
	  $self->exit($hash);
	};
	return $success;
};

sub alarms($) {
	my ($self,$hash) = @_;
	my $success = undef;
	eval {
  	if (my $firmata = main::FRM_Client_FirmataDevice($hash) and my $pin = $self->{pin} ) {
			$firmata->onewire_search_alarms($pin);
			$success = 1;
		};
	};
	if ($@) {
	  $self->exit($hash);
	};
	return $success;
};

sub execute($$$$$$$) {
	my ( $self, $hash, $context, $reset, $owx_dev, $data, $numread, $delay ) = @_;

  my $delayed = $self->{delayed};
  
  if ($owx_dev and my $queue = $delayed->{$owx_dev}) {
    if ($context or $reset or $data or $numread or $delay) {
      push @$queue->{items}, {
        context => $context,
        'reset' => $reset,
        device  => $owx_dev,
        data    => $data,
        numread => $numread,
        delay   => $delay
      };
    }
    if (tv_interval($queue->{'until'}) >= 0) {
      my $item = shift @$queue->{items};
      $context = $item->{context};
      $reset   = $item->{'reset'};
      $data    = $item->{data};
      $numread = $item->{numread};
      $delay   = $item->{delay};
      delete $self->{delayed}->{$owx_dev} unless (@$queue);
    } else {
      return 1;
    }
  }
	
	my $success = undef;
	eval {
  	if (my $firmata = main::FRM_Client_FirmataDevice($hash) and my $pin = $self->{pin} ) {
  		my @data = unpack "C*", $data if defined $data;
  		my $id = $self->{id} if ($numread);
  		my $ow_command = {
  			'reset'  => $reset,
  			'skip'   => defined ($owx_dev) ? undef : 1,
  			'select' => defined ($owx_dev) ? FRM_OWX_device_to_firmata($owx_dev) : undef,
  			'read'   => $numread,
  			'write'  => @data ? \@data : undef, 
  			'delay'  => undef,
  			'id'     => $numread ? $id : undef
  		};
  		if ($numread) {
  			$owx_dev = '00.000000000000.00' unless defined $owx_dev;
  			$self->{requests}->{$id} = {
  				context => $context,
  				command => $ow_command,
  				device  => $owx_dev
  			};
  			$self->{id} = (($id+1) & 0xFFFF);
  		};		
  		$firmata->onewire_command_series( $pin, $ow_command );
  		$success = 1;
  	};
	};
	if ($@) {
	  $self->exit($hash);
	};
	if ($success and $delay and $owx_dev) {
		unless ($delayed->{$owx_dev}) {
      $delayed->{$owx_dev} = { items => [] };
		}
		my ($seconds,$micros) = gettimeofday;
		my $len = length ($delay); #delay is millis, tv_address works with [sec,micros]
		if ($len>3) {
			$seconds += substr($delay,0,$len-3);
			$micros += (substr ($delay,$len-8).000);
		} else {
			$micros += ($delay.000);
		}
		$delayed->{$owx_dev}->{'until'} = [$seconds,$micros];
		main::InternalTimer("$seconds.$micros","OWX_Poll",$hash,1);
	}
	return $success;
};

sub exit($) {
	my ($self,$hash) = @_;
	main::OWX_Disconnected($hash);
};

sub poll($) {
  my ($self,$hash) = @_;
	if (my $frm = $hash->{IODev} ) {
    main::FRM_poll($frm);
    my $delayed = $self->{delayed};
    foreach my $address (keys %$delayed) {
      next if (tv_interval($delayed->{$address}->{'until'}) < 0);
      my @delayed_items = @{$delayed->{$address}->{'items'}}; 
  		my $item = shift @delayed_items;
  		delete $delayed->{$address} unless scalar(@delayed_items);# or $item->{delay};
  		$self->execute($hash,$item->{context},$item->{'reset'},$item->{device},$item->{data},$item->{numread},$item->{delay});
  		main::FRM_poll($frm);
  		last;
    }
	}   
};

1;